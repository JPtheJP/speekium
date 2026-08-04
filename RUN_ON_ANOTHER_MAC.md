# Run WhisprStream on another Apple Silicon Mac

WhisprStream runs natively on Apple Silicon. The source code and model cache
can be shared or cloned, but the Python virtual environment and app bundle
should be created on each Mac because the bundle stores that Mac's Python path.

## One-time setup

1. Install Xcode from the Mac App Store and launch it once. Accept the license
   if prompted.
2. Install Python 3.12. Homebrew is the simplest route:

   ```bash
   brew install python@3.12
   ```

3. Copy or clone this repository onto the Mac, then run:

   ```bash
   cd /path/to/whispr-stream
   ./setup-mac.sh
   ./WhisprStream/build.sh
   open WhisprStream.app
   ```

4. In the app, allow Microphone access. Also enable WhisprStream under
   System Settings → Privacy & Security → Accessibility so the global hotkey
   and paste action work.
5. Open Settings → Model and download `Qwen3-ASR 0.6B` (about 1.2 GB). The
   model is downloaded separately on each Mac and stays on-device.

## If you only want to copy the finished app

That is not sufficient by itself: the app needs the MLX Python packages and
model weights, and the current build embeds an absolute Python path. Rebuild
the app on the destination Mac using the commands above. This also creates a
stable local code-signing identity if you follow
`WhisprStream/make-signing-cert.md`.

## Updating the app

After pulling new source changes, rerun:

```bash
./WhisprStream/build.sh
open WhisprStream.app
```

Your model cache and app settings remain in your user Library. If the app was
rebuilt ad-hoc, re-add it in Accessibility after each rebuild; a stable
self-signed identity avoids that reset.

