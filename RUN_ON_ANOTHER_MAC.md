# Run Speekium on another Apple Silicon Mac

This document is for contributors building from source. Normal users should
follow [INSTALL.md](INSTALL.md) and download the GitHub Release; they do not
need Python, Xcode, Homebrew, or a virtual environment.

## One-time setup

1. Install Xcode from the Mac App Store and launch it once. Accept the license
   if prompted.
2. Install Python 3.12. Homebrew is the simplest route:

   ```bash
   brew install python@3.12
   ```

3. Copy or clone this repository onto the Mac, then run:

   ```bash
   cd /path/to/speekium
   ./setup-mac.sh
   ./Speekium/build.sh
   open Speekium.app
   ```

4. In the app, allow Microphone access. Also enable Speekium under
   System Settings → Privacy & Security → Accessibility so the global hotkey
   and paste action work.
5. Open Settings → Model and download `Qwen3-ASR 0.6B` (about 1.9 GB). The
   model is downloaded separately on each Mac and stays on-device.

## If you only want to copy the finished app

That is not sufficient by itself for a source build: the app needs the MLX
Python packages and model weights. Rebuild the app on the destination Mac using
the commands above. This also creates a stable local code-signing identity if you follow
`Speekium/make-signing-cert.md`.

## Updating the app

After pulling new source changes, rerun:

```bash
./Speekium/build.sh
open Speekium.app
```

Your model cache and app settings remain in your user Library. If the app was
rebuilt ad-hoc, re-add it in Accessibility after each rebuild; a stable
self-signed identity avoids that reset.
