# Security Hardening

Quake4Mac is a personal, noncommercial, macOS-first fork for the DK-QUAKE / ARIS-68 device. The goal of this hardening pass is to keep local development simple while making dangerous behavior explicit.

## Current Threat Model

- The app runs locally on the user's Mac and can interact with macOS apps, local files, network services, the Quake display, and the DK-QUAKE HID/VIA interfaces.
- Macro page JSON in `~/Library/Application Support/Quake4Mac/pages.json` is local configuration, but it can become executable content when it contains shell or AppleScript actions.
- Bundled web panels run from app resources in `WKWebView`. Swift pushes structured panel state through `JSONSerialization` and encoded JavaScript payloads.
- Bundled web panels must not execute remote JavaScript or stylesheet resources. Network data may still be fetched by panel code when the feature needs it, but executable resources should be bundled or avoided.
- Spotify refresh tokens are secrets. Client IDs, panel layout, wallpaper choices, RGB preferences, and UI settings are preferences.

## Device Safety Rules

- Do not add or run DFU, bootloader, firmware flashing, QMK flashing, `dfu-util`, or `avrdude` code.
- Do not run device smoke tests without explicit user approval.
- HID/VIA writes are allowed for normal app behavior only when they match existing user-visible features: panel wake/keep-alive, backlight changes, RGB ring settings, and reactive lighting.
- Manual debug writes such as RGB probe, self-test, effect tour, effect browser, and CPU heat simulation are hidden behind Developer Mode and must be triggered by the user.

## Secrets Policy

- Non-secret preferences stay in `UserDefaults`.
- Spotify refresh tokens are stored in the macOS Keychain through `KeychainStore`.
- The public Spotify client ID remains in `UserDefaults`.
- On launch, a legacy `spotify.refreshToken` value in `UserDefaults` is migrated to Keychain and removed from `UserDefaults`.

## Macro Shell and AppleScript Risk

Shell and AppleScript tile actions are powerful local code execution. They are disabled by default and routed through `MacroActionExecutor`.

Users can enable advanced macros in Settings when they trust their current page configuration. Shared or imported page configs should be reviewed as executable content before enabling these actions.

Executable macros have a timeout and bounded stderr capture. URL-opening macro actions and web dashboard pages are limited to `http` and `https` schemes.

## Web Panel Safety

- System strings, bookmark names, and weather location names are escaped before they enter HTML templates.
- Browser home bookmarks validate URL schemes and render DOM nodes directly instead of string-building interactive markup.
- Persistent `WKWebView` panels reload after WebContent process termination.
- Weather prewarm does not request Location permission at app launch; current location is requested when the interactive Weather screen appears.

## Permissions

The generated Info.plist declares the sensitive API reasons currently supported by the project settings:

- Location: local weather and Wi-Fi SSID context.
- Bluetooth: connected device names in System Monitor.
- Apple Events: AppleScript-based media and explicitly enabled macro actions.

Screen/System Audio capture is opt-in behavior for music-reactive lighting. The code starts capture only when that source is enabled, and no entitlement is added for it in this pass.

Private thermal sensors are disabled by default. The System Monitor can still show public GPU utilization; CPU/GPU temperature reads through private IOHIDEventSystem symbols only after enabling the explicit General -> Developer Mode setting.

No entitlement should be added unless a feature actually needs it.

## Build and Release Status

Local development is unsigned/ad-hoc by default and does not require an Apple Development Team ID:

```bash
xcodebuild -project Quake4Mac.xcodeproj -scheme Quake4Mac -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/quakeos-derived CODE_SIGNING_ALLOWED=NO build
```

Release has hardened runtime enabled, but Developer ID signing and notarization are not configured in this first pass.

## Testable Without Device

- Unsigned command-line build.
- Security guard script.
- Settings UI compile coverage.
- Keychain migration compile path.
- Macro execution disabled-by-default behavior by tapping a shell or AppleScript tile in the app.

## Requires Explicit Approval

- Any hardware smoke test.
- Any new HID/VIA debug write flow.
- Any device firmware, DFU, bootloader, or flashing-related experiment.
- Any new entitlement, privileged helper, or vendor binary blob.
