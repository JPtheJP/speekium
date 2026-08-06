#!/usr/bin/env python3
"""Compare legacy and optimized release-to-final ASR latency.

The recording is replayed in real time through the same live-preview loop used
by the app. Both algorithms share one warmed model session and alternate order
between trials to reduce thermal/order bias. The reported interval starts when
the user releases the trigger (Server.stop) and ends when the final JSON event
is emitted; model loading and the later 50 ms paste delay are intentionally
excluded.

Usage:
    .venv/bin/python benchmarks/asr_stop_latency.py --trials 3

WHISPR_MODEL, WHISPR_BITS, and WHISPR_CONTEXT match the app's sidecar settings.
"""

from __future__ import annotations

import argparse
import base64
import os
import sys
import threading
import time
import wave
from dataclasses import dataclass
from pathlib import Path

import numpy as np


ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "WhisprStream" / "Resources"
sys.path.insert(0, str(RESOURCES))

import asr_server  # noqa: E402


@dataclass
class Result:
    latency_ms: float
    text: str
    mode: str
    partial_count: int
    mean_partial_gap_ms: float
    max_partial_gap_ms: float


class EventCapture:
    def __init__(self):
        self.lock = threading.Lock()
        self.events: list[tuple[float, dict]] = []

    def emit(self, event: dict) -> None:
        with self.lock:
            self.events.append((time.perf_counter(), event))

    def clear(self) -> None:
        with self.lock:
            self.events.clear()

    def final(self) -> tuple[float, dict]:
        with self.lock:
            finals = [item for item in self.events if item[1].get("type") == "final"]
        if not finals:
            raise RuntimeError("sidecar did not emit a final event")
        return finals[-1]


def wav_blocks(path: Path, block_frames: int = 1600) -> tuple[list[str], float]:
    with wave.open(str(path), "rb") as wav:
        if wav.getframerate() != asr_server.SAMPLE_RATE or wav.getnchannels() != 1:
            raise ValueError(f"{path} must be mono {asr_server.SAMPLE_RATE} Hz")
        if wav.getsampwidth() != 2:
            raise ValueError(f"{path} must contain signed 16-bit PCM")
        total_frames = wav.getnframes()
        blocks = []
        while data := wav.readframes(block_frames):
            blocks.append(base64.b64encode(data).decode("ascii"))
    return blocks, total_frames / asr_server.SAMPLE_RATE


def replay(server: asr_server.Server, blocks: list[str], block_seconds: float) -> None:
    server.start()
    started = time.perf_counter()
    for index, block in enumerate(blocks):
        server.audio(block)
        deadline = started + (index + 1) * block_seconds
        remaining = deadline - time.perf_counter()
        if remaining > 0:
            time.sleep(remaining)


def legacy_stop(server: asr_server.Server) -> None:
    """The pre-optimization behavior: wait for preview, then always decode."""
    stop_started = time.perf_counter()
    server.active = False
    wait_started = time.perf_counter()
    if not server._join_preview_thread():
        raise RuntimeError("legacy preview decode did not stop")
    wait_ms = int((time.perf_counter() - wait_started) * 1000)

    with server.lock:
        audio = server.buf.copy()
        context = server.context
    seconds = len(audio) / asr_server.SAMPLE_RATE
    if seconds < asr_server.MIN_SECONDS:
        server._emit_final("", seconds, 0, stop_started, "legacy-too-short", wait_ms)
        return

    inference_started = time.perf_counter()
    text = server._decode(audio, context)
    inference_ms = int((time.perf_counter() - inference_started) * 1000)
    server._emit_final(
        text,
        seconds,
        inference_ms,
        stop_started,
        "legacy-fresh-final",
        wait_ms,
    )


def run_once(
    server: asr_server.Server,
    capture: EventCapture,
    blocks: list[str],
    block_seconds: float,
    algorithm: str,
) -> Result:
    capture.clear()
    replay(server, blocks, block_seconds)
    released = time.perf_counter()
    if algorithm == "legacy":
        legacy_stop(server)
    else:
        server.stop()
    emitted, event = capture.final()
    with capture.lock:
        partial_times = [
            timestamp
            for timestamp, item in capture.events
            if item.get("type") == "partial"
        ]
    partial_gaps = [
        (current - previous) * 1000
        for previous, current in zip(partial_times, partial_times[1:])
    ]
    return Result(
        latency_ms=(emitted - released) * 1000,
        text=event.get("text", ""),
        mode=event.get("mode", "unknown"),
        partial_count=len(partial_times),
        mean_partial_gap_ms=mean(partial_gaps) if partial_gaps else 0.0,
        max_partial_gap_ms=max(partial_gaps, default=0.0),
    )


def mean(values: list[float]) -> float:
    return sum(values) / len(values)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*", type=Path, default=[ROOT / "sample.wav", ROOT / "jargon.wav"])
    parser.add_argument("--trials", type=int, default=3)
    parser.add_argument("--block-ms", type=int, default=100)
    args = parser.parse_args()
    if args.trials < 1:
        parser.error("--trials must be at least 1")

    model = os.environ.get("WHISPR_MODEL", "Qwen/Qwen3-ASR-0.6B")
    bits = int(os.environ.get("WHISPR_BITS", "8"))
    context = os.environ.get("WHISPR_CONTEXT", "")

    capture = EventCapture()
    original_emit = asr_server.emit
    asr_server.emit = capture.emit
    try:
        server = asr_server.Server(model, bits, context)
        print(f"model={model} bits={bits} trials={args.trials} context_chars={len(context)}", flush=True)

        for raw_path in args.paths:
            path = raw_path if raw_path.is_absolute() else ROOT / raw_path
            blocks, duration = wav_blocks(path, int(args.block_ms / 1000 * asr_server.SAMPLE_RATE))
            results: dict[str, list[Result]] = {"legacy": [], "optimized": []}
            print(f"\n{path.name}: {duration:.2f}s audio", flush=True)

            for trial in range(args.trials):
                order = ("legacy", "optimized") if trial % 2 == 0 else ("optimized", "legacy")
                for algorithm in order:
                    result = run_once(
                        server,
                        capture,
                        blocks,
                        args.block_ms / 1000,
                        algorithm,
                    )
                    results[algorithm].append(result)
                    print(
                        f"  trial {trial + 1} {algorithm:9s}: "
                        f"{result.latency_ms:7.1f} ms  {result.mode}  "
                        f"partials={result.partial_count} "
                        f"gap_mean={result.mean_partial_gap_ms:.0f}ms "
                        f"gap_max={result.max_partial_gap_ms:.0f}ms",
                        flush=True,
                    )

            legacy_ms = [result.latency_ms for result in results["legacy"]]
            optimized_ms = [result.latency_ms for result in results["optimized"]]
            legacy_mean = mean(legacy_ms)
            optimized_mean = mean(optimized_ms)
            improvement = (legacy_mean - optimized_mean) / legacy_mean * 100
            all_text = [result.text for group in results.values() for result in group]
            identical = len(set(all_text)) == 1
            modes = ", ".join(sorted({result.mode for result in results["optimized"]}))

            print(
                f"  mean: legacy={legacy_mean:.1f} ms optimized={optimized_mean:.1f} ms "
                f"improvement={improvement:.1f}%",
                flush=True,
            )
            print(f"  optimized modes: {modes}; transcripts identical: {identical}", flush=True)
    finally:
        asr_server.emit = original_emit
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
