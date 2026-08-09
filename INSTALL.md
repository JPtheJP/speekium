# Install WhisprStream

WhisprStream is a free, open-source menu-bar dictation app for Apple-silicon Macs. It requires macOS 14 or later and approximately 3 GB free for the app, private speech engine, and recommended Qwen3-ASR 0.6B model.

## Download and open

1. Open [GitHub Releases](https://github.com/Leo6Leo/whispr-stream/releases) and download `WhisprStream-macos-arm64.zip` from the latest published release.
2. Extract the ZIP and move **WhisprStream** to your Applications folder.
3. Open WhisprStream normally.
4. If macOS blocks it, open **System Settings → Privacy & Security**. Find the WhisprStream message under Security, click **Open Anyway**, authenticate, and confirm **Open**.

The release is signed with WhisprStream's stable self-signed identity but is not notarized by Apple. The Open Anyway step is expected. Do not disable Gatekeeper globally.

## First launch

The app keeps the speech engine and speech model as separate downloads:

- The engine is approximately 100–150 MB compressed and 340–400 MB installed. It is stored in `~/Library/Application Support/WhisprStream/Runtime` and is reused across app updates.
- Qwen3-ASR 0.6B is approximately 1.9 GB installed and is recommended for most Macs. Plan for at least 3 GB free for a complete installation.
- Qwen3-ASR 1.7B is approximately 4.3 GB installed. It is larger and slower, may improve difficult audio, and is best with 16 GB or more unified memory. Plan for about 6 GB free.

The app checks available storage before either download and checks again before installing or extracting files. Model metadata is fetched from Hugging Face so the exact byte total can be shown.

## Permissions and menu-bar behavior

Onboarding asks for Microphone access and Accessibility access. Microphone is needed to capture speech; Accessibility is needed to see the trigger key globally and insert text at the cursor. If you choose **Skip for now**, the final screen will say **Finish setup later** and you can grant access from **Settings → Permissions**.

WhisprStream runs in the menu bar rather than the Dock. Choose **Setup Guide…** from the menu-bar icon to reopen onboarding. Choose **Settings…** for model, engine, permissions, vocabulary, shortcuts, and preferences.

## Recovery and storage cleanup

- If the engine is missing, incompatible, or fails its health check, open **Settings → Engine** and choose **Install** or **Repair / Reinstall**. Repair replaces only the engine; it does not delete models, preferences, vocabulary, or shortcuts.
- If a model download is interrupted, the app reports the scoped partial storage. Choose **Clear Partial Data** in **Settings → Model**. During a new download, **Clear and Continue** removes the unusable partial data before retrying; **Keep and Continue** leaves it in place. Cleanup affects only `.incomplete` files for the selected model.
- Download activity uses a crash-safe lock. Cancelling the operation or quitting unexpectedly releases the lock automatically, so stale state cannot permanently block cleanup.
- If a model is missing, open **Settings → Model** or **Setup Guide…**, select a model, and download it again.
- If permissions were revoked, open **Settings → Permissions** and use **Open Settings**.

## Updates

In **Settings → About**, choose **Check for Updates**. **Download Update…** opens the stable GitHub Release page. Download the new app ZIP, replace the app in Applications, and launch it. The runtime, models, settings, vocabulary, and shortcuts remain in your user Library.

## Uninstall

Remove these items separately according to what you want to keep:

- `/Applications/WhisprStream.app` — the native app.
- `~/Library/Application Support/WhisprStream/Runtime` — the private speech engine.
- `~/Library/Caches/huggingface/hub/models--Qwen--Qwen3-ASR-0.6B` and/or `models--Qwen--Qwen3-ASR-1.7B` — optional model caches. A custom `HF_HUB_CACHE` or `HF_HOME` location may be elsewhere.
- WhisprStream preferences in `~/Library/Preferences` — settings, vocabulary, and shortcuts.
- `~/Library/Logs/WhisprStream.log` — diagnostic logs.

Removing the app does not automatically remove the runtime, model caches, preferences, or logs.
