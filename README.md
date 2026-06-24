# Quake4Mac

A personal, macOS-first native app for the **DK‑QUAKE / ARIS‑68** — the ultra‑wide (1920×480) HDMI touchscreen + rotary knob with an RGB LED ring. Quake4Mac is an independent, open replacement for the vendor's DK‑Suite software, built in Swift / SwiftUI/AppKit.

> **Unofficial project.** Not affiliated with, endorsed by, or supported by DecoKee, MatrixZero, or TeeJS. "DK‑QUAKE", "ARIS‑68", and "DK‑Suite" are referenced for compatibility only.

---

## What it does

- **Springboard home screen** — an iOS‑style OS layer on the panel: a grid of app icons with page dots, a status bar (time / wifi / battery), and live video wallpapers behind it.
  - **Knob press = Home.** On the home screen, swipe left/right to change pages. Tap an icon to open an app.
- **Macro pages** — editable 8×2 tile grids (Apps / System / Web) that launch apps, open URLs, run shell commands or AppleScript, adjust panel brightness, or jump to another page. Edited from the Mac‑side settings with a live, 1:1 device preview and a drag‑and‑drop tile library.
- **Prebuilt panels:**
  - **Clock** — split‑flap, digital, or analog; single clock (swipe between time zones) or a world‑clock grid of analog faces.
  - **Music** — now‑playing with artwork and queue (Spotify).
  - **System Monitor** — CPU / GPU / memory / network / battery dashboard from native macOS APIs.
- **RGB knob ring** — QMK VIA lighting: effect, color, brightness, speed; plus reactive lighting (page‑theme, music, CPU).
- **Wallpapers** — looping video wallpapers, set globally or per home page (the Quake panel's wallpaper, not your Mac's).
- **Configurable launch** — open the panel to Home, a specific app, or the last‑opened screen.

## Requirements

- A **DK‑QUAKE / ARIS‑68** device (connects as a 1920×480 external display + USB‑HID knob/touch).
- **macOS 13 Ventura or later.** A few features (DRM‑safe system‑audio capture for music‑reactive lighting) need **macOS 14.4+**.
- **Xcode 15 or later** to build (developed against current Xcode).

## Build & run

```bash
git clone <your-repo-url>
cd QuakeOS
open Quake4Mac.xcodeproj
```

In Xcode: select the **Quake4Mac** scheme and press **⌘R** (Run).

Or from the command line:

```bash
xcodebuild -project Quake4Mac.xcodeproj -scheme Quake4Mac -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/quakeos-derived CODE_SIGNING_ALLOWED=NO build
```

The local command-line build is unsigned and does not require an Apple Developer account or Development Team ID. Release builds have hardened runtime enabled, but Developer ID signing/notarization are intentionally left for a later distribution step.

Plug in the DK‑QUAKE — the app auto‑detects the panel by name/size, pins its UI to it, and starts reading the knob/touch over USB‑HID. The settings window opens on your regular monitor.

You may be prompted to grant permissions depending on which features you use (e.g. Accessibility / Input Monitoring for global actions, System Audio Recording for music‑reactive lighting). Grant them in **System Settings → Privacy & Security**.

## Using the device

- **Knob press** → Home screen.
- **Swipe** on the home screen → change home page. **Tap** an icon → open that app.
- **In the Clock app** → swipe to flip between your configured time zones.
- Configure everything (pages, tiles, clocks, wallpaper, lighting, launch behavior) from the **Mac‑side settings window**.

Your settings are stored locally on your Mac (`~/Library/Preferences/com.quake4mac.app.plist` and `~/Library/Application Support/Quake4Mac/`) — they are **not** part of this repository, so cloning gives everyone a clean default setup.

## Security posture

- Spotify refresh tokens are stored in the macOS Keychain; non-secret preferences remain in `UserDefaults`.
- Shell and AppleScript macro tiles are disabled by default and must be enabled in Settings because shared page configs are executable content.
- URL-opening tiles and web dashboards accept only `http` and `https` URLs.
- Bundled web panels do not load remote executable scripts/styles; remote data APIs are still used by network-backed panels.
- Device debug actions that write to HID/VIA lighting interfaces are hidden behind Developer Mode and never run automatically.
- Private thermal sensor reads are disabled by default and can be enabled explicitly under Developer Mode.
- DFU, bootloader, firmware flashing, and device smoke tests require explicit user approval and are not part of normal development.

See [`docs/security-hardening.md`](docs/security-hardening.md) for the current hardening notes.

## Credits

- **DecoKee / MatrixZero** — creators of the DK‑QUAKE / ARIS‑68 hardware and the original DK‑Suite software. The bundled glyph icons and video wallpapers originate from DK‑Suite and remain the property of their owners.
- **TeeJS — [open-quake](https://github.com/TeeJS/open-quake)** — the open‑source HID driver/launcher whose reverse‑engineered protocol and feature set informed this project. open‑quake's launcher is MIT‑licensed; its reverse‑engineered protocol is under PolyForm Noncommercial.
- **Apple SF Symbols** — system iconography.

## License

Quake4Mac is released under the **Apache License 2.0** — see [`LICENSE`](LICENSE). You're free to use, modify, and redistribute it (including commercially), provided you keep the license and attribution notices intact, pass along the [`NOTICE`](NOTICE) file, and mark any files you change.

This project includes material derived from DecoKee's **DecoKeeAI / DK‑Suite** project (© DecoKee / MatrixZero), which is itself Apache‑2.0 licensed — the bundled glyph icons (`Quake4Mac/Icons/`), video wallpapers (`Quake4Mac/Wallpapers/`), and adapted reference assets. Those remain under Apache 2.0 and are credited in `NOTICE`; modified files note the change. The HID protocol/device behavior was also informed, as a reference only, by TeeJS's [open-quake](https://github.com/TeeJS/open-quake) (MIT) — no open-quake code is bundled here.

*Unofficial project, provided as‑is without warranty. Not affiliated with DecoKee, MatrixZero, or TeeJS. Nothing here is legal advice.*
