import sys
import threading
import unittest
from pathlib import Path

import numpy as np


RESOURCES = Path(__file__).parents[1] / "WhisprStream" / "Resources"
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


class PreviewReuseTests(unittest.TestCase):
    def make_server(self, text="hello", decoded_len=3200, revision=2, stable=True):
        server = asr_server.Server.__new__(asr_server.Server)
        server.lock = threading.Lock()
        server._last_preview_text = text
        server._last_preview_len = decoded_len
        server._last_preview_context_revision = revision
        server._last_preview_stable = stable
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

    def test_unstable_preview_with_silent_tail_falls_back(self):
        server = self.make_server(stable=False)
        audio = np.zeros(4000, dtype=np.float32)
        self.assertIsNone(server._reusable_preview(audio, 2))

    def test_context_change_falls_back(self):
        server = self.make_server()
        audio = np.zeros(3200, dtype=np.float32)
        self.assertIsNone(server._reusable_preview(audio, 3))

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
