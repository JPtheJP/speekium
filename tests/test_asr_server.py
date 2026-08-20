import sys
import threading
import unittest
from unittest.mock import patch
from pathlib import Path
from types import SimpleNamespace

import numpy as np


RESOURCES = Path(__file__).parents[1] / "Speekium" / "Resources"
sys.path.insert(0, str(RESOURCES))

import asr_server  # noqa: E402


class SilenceDetectionTests(unittest.TestCase):
    def test_audio_buffer_has_headroom_over_ui_limit(self):
        self.assertGreater(asr_server.MAX_BUFFER_SEC, 45.0)

    def test_room_noise_is_silence(self):
        rng = np.random.default_rng(7)
        audio = rng.normal(0, 0.008, int(0.4 * asr_server.SAMPLE_RATE)).astype(np.float32)
        self.assertTrue(asr_server.is_confident_silence(audio))

    def test_quiet_speech_level_is_not_silence(self):
        samples = np.arange(int(0.2 * asr_server.SAMPLE_RATE), dtype=np.float32)
        audio = 0.035 * np.sin(2 * np.pi * 180 * samples / asr_server.SAMPLE_RATE)
        self.assertFalse(asr_server.is_confident_silence(audio))

    def test_transient_is_not_silence(self):
        audio = np.zeros(int(0.2 * asr_server.SAMPLE_RATE), dtype=np.float32)
        audio[len(audio) // 2] = 0.08
        self.assertFalse(asr_server.is_confident_silence(audio))

    def test_room_noise_does_not_count_as_speech(self):
        rng = np.random.default_rng(7)
        audio = rng.normal(0, 0.008, int(0.4 * asr_server.SAMPLE_RATE)).astype(np.float32)
        self.assertFalse(asr_server.has_speech(audio))

    def test_quiet_voice_counts_as_speech(self):
        samples = np.arange(int(0.2 * asr_server.SAMPLE_RATE), dtype=np.float32)
        audio = 0.035 * np.sin(2 * np.pi * 180 * samples / asr_server.SAMPLE_RATE)
        self.assertTrue(asr_server.has_speech(audio))

    def test_single_loud_click_does_not_count_as_speech(self):
        audio = np.zeros(int(0.4 * asr_server.SAMPLE_RATE), dtype=np.float32)
        window = int(asr_server.SILENCE_WINDOW_SEC * asr_server.SAMPLE_RATE)
        audio[window:2 * window] = 0.5
        self.assertFalse(asr_server.has_speech(audio))

    def test_silent_final_never_calls_decoder_or_reuses_context_hallucination(self):
        server = asr_server.Server.__new__(asr_server.Server)
        server.lock = threading.Lock()
        server.buf = np.zeros(asr_server.SAMPLE_RATE, dtype=np.float32)
        server.context = "Claude"
        server._context_revision = 0
        server._thread = None
        server._preview_stop = threading.Event()
        server.active = True

        with patch.object(server, "_decode", side_effect=AssertionError("decoded silence")), \
             patch.object(server, "_reusable_preview", side_effect=AssertionError("reused silence")), \
             patch.object(asr_server, "emit") as emitted:
            server.stop()

        final = emitted.call_args.args[0]
        self.assertEqual(final["type"], "final")
        self.assertEqual(final["text"], "")
        self.assertEqual(final["mode"], "no-speech")


class PreviewSchedulingTests(unittest.TestCase):
    def test_short_utterances_keep_original_cadence(self):
        self.assertEqual(
            asr_server.preview_cooldown(4.0, 0.4),
            asr_server.POLL_INTERVAL,
        )

    def test_medium_utterances_ramp_toward_idle_decoder(self):
        self.assertAlmostEqual(
            asr_server.preview_cooldown(6.0, 0.45),
            0.45,
        )

    def test_eight_second_utterances_target_one_third_decoder_duty(self):
        self.assertAlmostEqual(
            asr_server.preview_cooldown(8.0, 0.45),
            0.9,
        )

    def test_cooldown_is_capped(self):
        self.assertEqual(
            asr_server.preview_cooldown(45.0, 4.0),
            asr_server.PREVIEW_MAX_COOLDOWN_SEC,
        )

    def test_windowed_preview_uses_faster_hud_cadence(self):
        cooldown = asr_server.preview_cooldown(45.0, 0.5, windowed=True)
        self.assertAlmostEqual(cooldown, 0.375)

    def test_windowed_preview_cooldown_is_capped(self):
        self.assertEqual(
            asr_server.preview_cooldown(45.0, 2.0, windowed=True),
            asr_server.WINDOWED_PREVIEW_MAX_COOLDOWN_SEC,
        )

    def test_short_preview_keeps_complete_audio(self):
        audio = np.arange(8 * asr_server.SAMPLE_RATE, dtype=np.float32)
        preview, start = asr_server.preview_audio(audio)
        self.assertEqual(start, 0)
        np.testing.assert_array_equal(preview, audio)

    def test_long_preview_keeps_only_recent_window(self):
        audio = np.arange(45 * asr_server.SAMPLE_RATE, dtype=np.float32)
        preview, start = asr_server.preview_audio(audio)
        expected_len = int(asr_server.PREVIEW_MAX_AUDIO_SEC * asr_server.SAMPLE_RATE)
        self.assertEqual(len(preview), expected_len)
        self.assertEqual(start, len(audio) - expected_len)
        np.testing.assert_array_equal(preview, audio[-expected_len:])


class ShortUtteranceLanguageTests(unittest.TestCase):
    class FakeSession:
        def __init__(self):
            self.calls = []

        def transcribe(self, _audio, **kwargs):
            self.calls.append(kwargs)
            return SimpleNamespace(text=" testing ")

    def make_server(self, language):
        server = asr_server.Server.__new__(asr_server.Server)
        server.session = self.FakeSession()
        server.short_utterance_language = language
        server._utterance_short_language = language
        return server

    def test_preference_values_map_to_model_language_names(self):
        self.assertEqual(
            asr_server.normalize_short_utterance_language("english"),
            "English",
        )
        self.assertEqual(
            asr_server.normalize_short_utterance_language("CHINESE"),
            "Chinese",
        )
        self.assertEqual(
            asr_server.normalize_short_utterance_language("macedonian"),
            "Macedonian",
        )
        self.assertIsNone(
            asr_server.normalize_short_utterance_language("automatic")
        )

    def test_all_official_languages_are_available(self):
        self.assertEqual(len(asr_server.SUPPORTED_SHORT_UTTERANCE_LANGUAGES), 30)
        for language in asr_server.SUPPORTED_SHORT_UTTERANCE_LANGUAGES:
            self.assertEqual(
                asr_server.normalize_short_utterance_language(language),
                language,
            )

    def test_short_final_uses_preferred_language(self):
        server = self.make_server("English")
        audio = np.zeros(
            int(asr_server.SHORT_UTTERANCE_MAX_SEC * asr_server.SAMPLE_RATE),
            dtype=np.float32,
        )

        self.assertEqual(server._decode_final(audio, "Codex"), "testing")
        self.assertEqual(
            server.session.calls,
            [{"context": "Codex", "language": "English"}],
        )

    def test_short_preview_remains_automatic(self):
        server = self.make_server("English")
        audio = np.zeros(asr_server.SAMPLE_RATE, dtype=np.float32)

        self.assertEqual(server._decode_preview(audio, "Codex"), "testing")
        self.assertEqual(server.session.calls, [{"context": "Codex"}])

    def test_longer_clip_remains_automatic(self):
        server = self.make_server("English")
        audio = np.zeros(
            int(asr_server.SHORT_UTTERANCE_MAX_SEC * asr_server.SAMPLE_RATE) + 1,
            dtype=np.float32,
        )

        server._decode_final(audio, "")
        self.assertEqual(server.session.calls, [{}])

    def test_automatic_mode_never_forces_language(self):
        server = self.make_server(None)
        server._decode_final(
            np.zeros(asr_server.SAMPLE_RATE, dtype=np.float32),
            "",
        )
        self.assertEqual(server.session.calls, [{}])

    def test_per_utterance_hint_overrides_configured_language(self):
        server = self.make_server("English")
        server._utterance_short_language = "Chinese"
        audio = np.zeros(asr_server.SAMPLE_RATE, dtype=np.float32)

        server._decode_final(audio, "")
        self.assertEqual(server.session.calls, [{"language": "Chinese"}])


class PreviewReuseTests(unittest.TestCase):
    def make_server(self, text="hello", decoded_len=3200, revision=2, stable=True):
        server = asr_server.Server.__new__(asr_server.Server)
        server.lock = threading.Lock()
        server._last_preview_text = text
        server._last_preview_len = decoded_len
        server._last_preview_start = 0
        server._last_preview_context_revision = revision
        server._last_preview_language = None
        server._last_preview_stable = stable
        server.short_utterance_language = None
        server._utterance_short_language = None
        return server

    def test_exact_buffer_is_reused(self):
        server = self.make_server()
        audio = np.zeros(3200, dtype=np.float32)
        self.assertEqual(server._reusable_preview(audio, 2), ("hello", "reuse-exact", 0))

    def test_stable_preview_with_silent_tail_is_reused(self):
        server = self.make_server()
        audio = np.zeros(4000, dtype=np.float32)
        self.assertEqual(
            server._reusable_preview(audio, 2),
            ("hello", "reuse-silent-tail", 800),
        )

    def test_stable_preview_remains_reusable_across_adaptive_cooldown(self):
        server = self.make_server(decoded_len=3200)
        tail = int(1.8 * asr_server.SAMPLE_RATE)
        audio = np.zeros(3200 + tail, dtype=np.float32)
        self.assertEqual(
            server._reusable_preview(audio, 2),
            ("hello", "reuse-silent-tail", tail),
        )

    def test_silent_tail_beyond_adaptive_headroom_falls_back(self):
        server = self.make_server(decoded_len=3200)
        tail = int(2.1 * asr_server.SAMPLE_RATE)
        audio = np.zeros(3200 + tail, dtype=np.float32)
        self.assertIsNone(server._reusable_preview(audio, 2))

    def test_unstable_preview_with_silent_tail_falls_back(self):
        server = self.make_server(stable=False)
        audio = np.zeros(4000, dtype=np.float32)
        self.assertIsNone(server._reusable_preview(audio, 2))

    def test_context_change_falls_back(self):
        server = self.make_server()
        audio = np.zeros(3200, dtype=np.float32)
        self.assertIsNone(server._reusable_preview(audio, 3))

    def test_preview_is_not_reused_across_short_language_boundary(self):
        decoded_len = int(1.9 * asr_server.SAMPLE_RATE)
        server = self.make_server(decoded_len=decoded_len)
        server.short_utterance_language = "English"
        server._utterance_short_language = "English"
        server._last_preview_language = None
        audio = np.zeros(decoded_len, dtype=np.float32)

        self.assertIsNone(server._reusable_preview(audio, 2))

    def test_automatic_preview_can_be_reused_for_long_final(self):
        decoded_len = int(2.1 * asr_server.SAMPLE_RATE)
        server = self.make_server(decoded_len=decoded_len)
        server.short_utterance_language = "English"
        server._utterance_short_language = "English"
        server._last_preview_language = None
        audio = np.zeros(decoded_len, dtype=np.float32)

        self.assertEqual(
            server._reusable_preview(audio, 2),
            ("hello", "reuse-exact", 0),
        )

    def test_rolling_window_preview_is_never_reused_as_full_final(self):
        server = self.make_server(decoded_len=3200)
        server._last_preview_start = 800
        audio = np.zeros(3200, dtype=np.float32)
        self.assertIsNone(server._reusable_preview(audio, 2))

    def test_voiced_tail_falls_back(self):
        server = self.make_server()
        audio = np.zeros(4000, dtype=np.float32)
        audio[3200:] = 0.08
        self.assertIsNone(server._reusable_preview(audio, 2))

    def test_timed_out_cleanup_is_preserved_then_can_be_awaited(self):
        class SlowThread:
            def __init__(self):
                self.alive = True
                self.timeouts = []

            def join(self, timeout=None):
                self.timeouts.append(timeout)
                if timeout is None:
                    self.alive = False

            def is_alive(self):
                return self.alive

        server = self.make_server()
        thread = SlowThread()
        server._thread = thread

        self.assertFalse(server._join_preview_thread())
        self.assertIs(server._thread, thread)
        self.assertTrue(server._join_preview_thread(timeout=None))
        self.assertIsNone(server._thread)
        self.assertEqual(thread.timeouts, [5.0, None])


if __name__ == "__main__":
    unittest.main()
