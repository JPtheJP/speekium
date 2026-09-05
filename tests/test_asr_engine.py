import importlib.util
import sys
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pytest

MODULE_PATH = Path(__file__).parents[1] / "Speekium" / "Resources" / "asr_engine.py"
SPEC = importlib.util.spec_from_file_location("speekium_asr_engine", MODULE_PATH)
asr_engine = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = asr_engine
SPEC.loader.exec_module(asr_engine)


def test_whisper_adapter_routes_model_prompt_and_language(monkeypatch):
    calls = []

    def transcribe(audio, **options):
        calls.append((audio, options))
        return {"text": " hello ", "language": "en"}

    monkeypatch.setitem(sys.modules, "mlx_whisper", SimpleNamespace(transcribe=transcribe))
    session = asr_engine.WhisperSession("mlx-community/whisper-small-mlx")
    audio = np.zeros(320, dtype=np.float32)

    result = session.transcribe(audio, context="Speekium", language="English")

    assert result.text == " hello "
    assert result.language == "en"
    assert calls == [(audio, {
        "path_or_hf_repo": "mlx-community/whisper-small-mlx",
        "verbose": None,
        "initial_prompt": "Speekium",
        "language": "en",
    })]


def test_whisper_adapter_omits_unknown_language_hint(monkeypatch):
    options_seen = []
    fake = SimpleNamespace(
        transcribe=lambda _audio, **options: options_seen.append(options) or {"text": "ok"}
    )
    monkeypatch.setitem(sys.modules, "mlx_whisper", fake)

    session = asr_engine.WhisperSession("/tmp/local-model")
    session.transcribe(np.zeros(1, dtype=np.float32), language="Unknown")

    assert "language" not in options_seen[0]


def test_build_session_rejects_unknown_engine_before_loading_dependencies():
    with pytest.raises(ValueError, match="unsupported speech engine"):
        asr_engine.build_session("anything", engine="other", warm=False)
