# Repository Instructions

## Project Shape

QuakeOS is the repo name; the app target is `Quake4Mac`. It is a native macOS SwiftUI/AppKit application for the DK-QUAKE / ARIS-68 1920x480 external touchscreen, rotary knob, and RGB ring.

The project is an Xcode app project, not a Swift Package:

- Xcode project: `Quake4Mac.xcodeproj`
- Scheme/target: `Quake4Mac`
- Bundle identifier: `com.quake4mac.app`
- Swift version: 5.0
- Minimum macOS target: 13.0

Do not add a package manager, generated project structure, or unrelated build wrapper unless the user asks for it.

## Build And Verification

Use a repo-local derived data path so command-line builds do not write into the user's global Xcode directories:

```bash
xcodebuild -project Quake4Mac.xcodeproj -scheme Quake4Mac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

There is no test target in the project at the time this file was created. For source changes, at minimum run the build above. For docs-only changes, inspect the rendered Markdown and `git diff`.

The CLI verification build disables code signing so agents do not depend on a local Mac Development certificate. If `xcodebuild` prints CoreSimulator or Xcode log-store warnings while building the macOS target, treat them as environment noise unless the command exits nonzero or the build fails. The success signal is `** BUILD SUCCEEDED **`.

For Calendar, Input Monitoring, LaunchServices, `NSWorkspace`, EventKit, privacy prompts, and other system-integrated macOS behavior, treat a normal `.app` launch path as the source of truth for QA. Use `Xcode Run`, `open -n <Quake4Mac.app>`, or another LaunchServices-backed app launch for real integration verification. Direct execution of `Quake4Mac.app/Contents/MacOS/Quake4Mac` is allowed only for low-level debugging and must not be treated as authoritative for TCC identity, prompt routing, or system-integration behavior.

## Directory Map

- `Quake4Mac/App`: app lifecycle, display selection, settings windows, menu bar, panel sleep prevention, and persistent `WKWebView` infrastructure.
- `Quake4Mac/Device`: HID discovery and input/output for knob, touch, backlight, keep-alive, and QMK VIA RGB ring commands.
- `Quake4Mac/Macro`: macro page model, tile action execution, tile persistence, and the web-backed macro screen renderer.
- `Quake4Mac/Home`: springboard home screen, home layout editing, wallpaper, browser, on-device settings app, weather, geocoding, and location service.
- `Quake4Mac/Clock`, `Quake4Mac/Music`, `Quake4Mac/SystemMonitor`: built-in panel implementations and their settings/model helpers.
- `Quake4Mac/UI/Settings`: Mac-side settings app, sidebar, preview strip, neon controls/theme, and panel editors.
- `Quake4Mac/Web`: bundled HTML/CSS/JS renderers loaded by local `WKWebView`s.
- `Quake4Mac/Icons` and `Quake4Mac/Wallpapers`: bundled visual assets. Treat these as licensed assets; update `NOTICE` when attribution-relevant asset changes are made.

The `.xcodeproj` uses explicit groups and build phases. When adding Swift files or resources, make sure they are included in the Xcode project, not just present on disk.

## Architecture Rules

- The device UI is fixed-format. Preserve 1920x480 assumptions, 8x2 macro tile geometry, normalized touch coordinates, and matching hit-test/layout metrics.
- `Quake4MacApp.swift` owns app startup. `AppState.input.onEvent` routes hardware input into `PadModel.handle(_:)` and `RGBReactiveEngine`.
- `QuakeDisplay.screen()` should identify the real panel by name, by 1920x480-ish size, or by the `QUAKE_SCREEN` override. Do not add fallback logic that can hijack unrelated external displays during runtime reattach.
- `PanelWeb.swift` is the shared persistent webview path for pre-warmed panels. `PanelWarmer.warmAll()` currently warms Clock, Monitor, and Weather. The persistent Music webview exists but is intentionally dormant until on-device verification; keep `MusicScreenView` as the active Music path unless the task is explicitly to verify and switch it.
- Web panel state is pushed from Swift into bundled pages with `evaluateJavaScript`. Encode structured data with `JSONSerialization` and safely encode it before injecting into JavaScript. Avoid direct string interpolation of user-controlled content.
- Settings and small preferences use `UserDefaults`. Macro page layout persists as JSON in `~/Library/Application Support/Quake4Mac/pages.json`. Do not commit local runtime state.
- Hardware features should degrade gracefully when the DK-QUAKE panel, knob, touch device, Spotify account, location permission, or network is unavailable.

## Coding Style

- Follow the existing SwiftUI/AppKit style: `ObservableObject`, `@Published`, `@ObservedObject`, `NSViewRepresentable`, and focused model/store singletons where the repo already uses them.
- Keep comments for hardware quirks, protocol details, and lifecycle traps. Avoid comments that restate obvious Swift.
- Prefer extending existing modules over creating new architectural layers.
- Match existing `// MARK: - ...` organization in Swift files.
- Keep settings UI consistent with the existing neon theme and preview-strip patterns.
- Do not make unrelated formatting sweeps, project-file churn, or broad refactors while solving a narrow task.

## Hardware And Manual QA

Some behavior cannot be fully verified without the physical DK-QUAKE / ARIS-68 device:

- panel detection and window pinning
- knob turn/press input
- touchscreen routing and scroll-vs-swipe behavior
- RGB ring effects and reactive lighting
- panel wake/backlight HID output

When hardware is not available, build the app and state clearly which hardware paths remain unverified. For manual screen targeting, the app supports `QUAKE_SCREEN=<index>`.

## Privacy, Secrets, And Networked Features

- Do not commit Spotify refresh tokens, local preferences, derived data, logs, or user-specific `Application Support` files.
- Keep API-key-free weather behavior unless the user explicitly changes the provider design.
- If adding permissions, update generated Info.plist keys in `Quake4Mac.xcodeproj/project.pbxproj` and explain the user-facing reason.

## Git Hygiene

Before editing, check `git status --short` and preserve user changes. Ignore generated outputs such as `build/`, `.build/`, `DerivedData/`, `xcuserdata/`, and `.DS_Store`; these are already covered by `.gitignore`.
