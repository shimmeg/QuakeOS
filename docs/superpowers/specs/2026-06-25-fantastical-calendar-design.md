# Fantastical Calendar Panel Design

Date: 2026-06-25

## Goal

Add a Quake home app for Fantastical that opens a built-in Calendar panel showing today's events. The panel reads macOS calendars through EventKit, while Fantastical remains an external handoff target for full calendar editing.

## Root Problem

The first implementation mixed three concerns in one flow:

1. calendar data loading through EventKit,
2. Calendar permission prompting through macOS TCC,
3. DK-QUAKE-specific runtime behavior and touch interaction.

That coupling created confusing behavior during development:

- permission attribution changed depending on how the process was launched,
- permission prompts could appear on the Quake display instead of the main Mac display,
- temporary launch-time bootstrap logic was introduced to force prompts to appear.

The proper fix is not another bootstrap. The fix is to separate data, permission control, and external Fantastical launch, then test macOS integrations only through the normal app lifecycle.

## Options Considered

1. Keep the current implementation and remove only the temporary debug hooks.
   - Rejected. It reduces noise, but it preserves the main design issue: UI, EventKit, permission flow, and Fantastical launch are still tightly coupled inside one file.

2. Split calendar concerns into dedicated modules and make macOS Settings the primary permission surface.
   - Selected. This keeps EventKit integration native, keeps Fantastical as a clean external handoff, removes launch-time permission hacks, and gives a normal macOS testing path.

3. Build a shared permission framework for the whole app now.
   - Deferred. This is a reasonable next step for Calendar plus Input Monitoring, but it is broader than the current feature and would expand scope unnecessarily.

## Product Scope

- The Home catalog and default Home page expose a red `Fantastical` app icon.
- Tapping `Fantastical` opens a Quake-native `calendar` panel.
- The Quake panel renders today's events from EventKit.
- Fantastical remains available as an `Open Fantastical` action when installed.
- Calendar permission is managed from the macOS Settings window for Quake4Mac, not from launch-time bootstrap logic.

Out of scope for this pass:

- calendar filtering by account or source,
- event editing inside Quake4Mac,
- a generalized permission framework shared by Calendar and Input Monitoring,
- any direct embedding of Fantastical UI.

## User Experience

### Quake Panel

- The panel shows the current date, permission state, and today's events.
- When authorized, the panel renders all-day events first, then timed events, with `isNow` and `isNext` emphasis.
- When no events exist, the panel shows an empty-day state.
- When Fantastical is installed, the panel shows an `Open Fantastical` action.

The Quake panel is intentionally not the primary permission surface:

- `notDetermined`: explain that Calendar access must be granted from the Mac-side settings window.
- `denied` or `restricted`: explain that access is off and offer `Open Settings`.
- `authorized`: show today's schedule.

This keeps the permission prompt off the DK-specific interaction path and avoids depending on Quake touch behavior to approve a system prompt.

### Mac-Side Settings

`Prebuilt Panels -> Fantastical` becomes the primary control surface for this integration.

The settings page shows:

- current Calendar authorization state,
- explicit `Grant Calendar Access` action when status is `notDetermined`,
- explicit `Open Privacy Settings` action when status is `denied` or `restricted`,
- Fantastical install status,
- `Open Fantastical` action for external handoff.

Calendar permission should only be requested after an explicit user action from this Mac-side settings view. No automatic request at launch, and no hidden bootstrap through `UserDefaults`.

## Architecture

The implementation should keep clear ownership boundaries:

- `CalendarPanelModels.swift`
  - pure view-state types and deterministic formatting logic,
  - no EventKit, no AppKit, no `UserDefaults`.

- `CalendarPermissionController`
  - owns EventKit authorization status checks,
  - requests Calendar permission,
  - opens macOS Calendar privacy settings,
  - exposes permission state changes to consumers.

- `CalendarEventsService`
  - owns `EKEventStore` event queries for today's interval,
  - converts `EKEvent` values into `CalendarPanelEventSummary`,
  - contains no UI branching and no permission-prompt logic.

- `FantasticalLauncher`
  - checks whether Fantastical is installed,
  - opens the Fantastical app,
  - does not participate in permission or event-loading logic.

- `CalendarPanelStore`
  - composes permission state, today's events, and launcher availability into a `CalendarPanelSnapshot`,
  - serves both the Quake panel web renderer and the Mac-side Settings view,
  - refreshes when the app becomes active again after a user changes permission settings.

- `CalendarScreen.swift`
  - contains the web host, script bridge, and Settings SwiftUI view,
  - does not contain raw EventKit permission logic or launch-time bootstrap behavior.

## Data Model

The panel snapshot contains:

- `status`: `notDetermined`, `requesting`, `authorized`, `denied`, `restricted`, or `error`
- `dateTitle`: localized display date for today
- `message`: localized status/empty-state text
- `events`: ordered event summaries
- `canOpenFantastical`: whether `NSWorkspace` can find Fantastical

Each event summary contains:

- stable id string
- title
- start and end timestamps
- formatted time range
- all-day flag
- calendar name
- calendar color hex
- optional location
- `isNow` and `isNext` flags

Today's bounds use `Calendar.current.startOfDay(for:)` through the next local day, so the panel respects the user's timezone and locale.

## Permissions

Add calendar access usage descriptions to generated Info.plist settings in `Quake4Mac.xcodeproj/project.pbxproj`:

- `NSCalendarsUsageDescription` for macOS 13 compatibility.
- `NSCalendarsFullAccessUsageDescription` for the macOS 14+ full-access EventKit request.

User-facing copy:

> Quake4Mac reads your calendars to show today's events on the Quake panel.

Permission behavior requirements:

- On macOS 14 and newer, request full event access.
- On macOS 13, use the older EventKit event access request.
- Never request Calendar permission automatically at app launch.
- Never depend on a temporary `requestAccessAtLaunch` flag or similar bootstrap path.

## Development And QA Rules

Repository-level guidance must be updated so this feature is tested the way macOS apps are normally tested.

For Calendar, Input Monitoring, LaunchServices, `NSWorkspace`, EventKit, privacy prompts, and other system integrations:

- the source of truth is a normal `.app` launch path,
- recommended verification paths are `Xcode Run`, `open -n <Quake4Mac.app>`, or another LaunchServices-backed app launch,
- direct execution of `Quake4Mac.app/Contents/MacOS/Quake4Mac` is allowed only for low-level hardware debugging and must not be treated as authoritative for TCC, app identity, prompt routing, or system-integration behavior.

This requirement belongs in `AGENTS.md` because it is repository-wide development guidance, not calendar-specific business logic.

## Settings And Panel Behavior

- The Quake panel may show `Open Settings` when access is needed, but the primary `Grant Calendar Access` button lives in the Mac-side settings UI.
- The panel still supports scrolling and Fantastical launching through the existing `PanelWeb` and touch-routing model.
- No calendar filtering UI is included in this pass.

## Verification

### Automated

- Keep focused logic verification for pure date-window and event-formatting behavior without introducing a package manager.
- Run the repository compile-safety build:

```bash
xcodebuild -project Quake4Mac.xcodeproj -scheme Quake4Mac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

### Manual macOS Integration QA

Run the real integration check only from a normal app launch path:

1. Build and run Quake4Mac through Xcode Run or open the built `.app` with LaunchServices.
2. Open `Prebuilt Panels -> Fantastical` in the Mac-side settings window.
3. Trigger `Grant Calendar Access`.
4. Verify the system prompt attributes access to `Quake4Mac`.
5. Verify `Quake4Mac` appears in `System Settings -> Privacy & Security -> Calendars`.
6. Grant access and confirm today's events appear on the Quake panel.
7. Verify `Open Fantastical` launches the external app when installed.

Hardware-specific touch, panel wake, and physical display placement still require the DK-QUAKE / ARIS-68 device for full manual verification.
