
## Download

1. Download **RAVE-LIVE.dmg** below (under Assets) and double-click it.
2. Drag **RAVE LIVE** onto the **Applications** shortcut in the window that opens.
3. Open RAVE LIVE from Applications. It isn't notarized by Apple, so macOS will say it can't verify the app. Click **Done**, open **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to RAVE LIVE, then confirm. You only do this once.
4. Allow **Screen & System Audio Recording** when asked. macOS needs it to let RAVE LIVE hear what your Mac is playing; nothing is recorded.

Prefer one command? Paste this into Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/jedbrnth-eng/rave-live/main/install.sh | bash
```

Runs on Apple silicon and Intel Macs with macOS 12 Monterey or later (system audio capture needs macOS 13; on macOS 12 pick an input in the Audio menu, see docs/COMPATIBILITY.md). Please read the photosensitivity warning in the README before using strobes.
