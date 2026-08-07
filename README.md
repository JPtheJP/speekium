<p align="center">
  <img src="assets/whisprstream-logo.png" alt="WhisprStream" width="520">
</p>

<p align="center">Fast, private, multilingual dictation for Apple silicon Macs.</p>

<p align="center">
  <img src="assets/whisprstream-preview.png" alt="WhisprStream floating dictation HUD" width="900">
</p>

WhisprStream is an open-source macOS dictation app that types at your cursor while you speak. It runs locally, keeps the model warm for low latency, and follows mixed-language sentences without uploading audio. Use it in any app—from notes and email to your terminal and coding agent.

## Highlights

- Live transcription with a floating HUD
- Multilingual dictation: switch languages mid-sentence, without being limited to Chinese and English—or to two languages at a time
- Custom vocabulary for names, technical terms, and jargon
- Voice shortcuts that expand a spoken phrase into a URL, signature, address, reusable reply, or any text you type often
- Bring your own compatible ASR model, including base or fine-tuned checkpoints
- Non-streaming models can still produce a live preview: WhisprStream repeatedly re-reads the growing utterance and settles the stable words
- No account, server, or audio upload

## Requirements

- macOS 14 or later
- Apple silicon Mac
- Python 3.12 and Xcode

## Build and run

```bash
./setup-mac.sh
WhisprStream/build.sh
open WhisprStream.app
```

On first launch, open Settings → Model to download the speech model. Hold the Right Option key, speak, and release; the transcript is inserted into the active app.

## Open source and model flexibility

WhisprStream is MIT licensed and designed to be inspected, adapted, and extended. The default app offers Qwen3-ASR models, but the ASR sidecar is replaceable: add a compatible local model or fine-tuned checkpoint and keep the rest of the dictation workflow. A model does not need native streaming support. WhisprStream can repeatedly transcribe the full utterance, preserve context across language switches, and turn stable output into a live stream.

The native Swift front end and Python ASR sidecar communicate locally over a small newline-delimited JSON protocol. See [HANDOFF.md](HANDOFF.md) for architecture notes and troubleshooting.

## License

WhisprStream is available under the [MIT License](LICENSE).
