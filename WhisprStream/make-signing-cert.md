# Stop re-granting Accessibility after every rebuild

macOS ties an Accessibility grant to the app's **code signature**. An ad-hoc
signature (`codesign --sign -`) is derived from the binary hash, so every rebuild
produces a new identity, the old grant no longer matches, and the hotkey and
paste both silently stop working.

A self-signed certificate fixes this permanently: the identity stays constant, so
the grant survives rebuilds. One-time setup, about a minute.

## Create the certificate

1. Open **Keychain Access** (⌘Space → "Keychain Access")
2. Menu: **Keychain Access → Certificate Assistant → Create a Certificate…**
3. Fill in:
   - **Name:** `WhisprStream Self-Signed`  ← must match exactly, `build.sh` looks for it
   - **Identity Type:** Self Signed Root
   - **Certificate Type:** **Code Signing**
4. Click **Create**, then **Done**

## Rebuild

```bash
WhisprStream/build.sh
```

It should now print `▸ signing with stable identity`.

## Re-grant once more

The signature changed one final time, so:

**System Settings → Privacy & Security → Accessibility** → select WhisprStream →
**remove it (−)** → **add it back (+)** → make sure the toggle is on.

From here rebuilds keep the grant.

## Checking

`~/Library/Logs/WhisprStream.log` records the state at every launch:

```
[whispr] launch: accessibility=granted
```

If it says `DENIED`, the hotkey and paste will both do nothing.
