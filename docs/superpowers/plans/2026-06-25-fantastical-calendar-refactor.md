# Fantastical Calendar Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor the Fantastical calendar panel into clean permission, event, and presentation boundaries, remove launch-time permission hacks, and codify correct macOS integration QA in the repository instructions.

**Architecture:** Keep `CalendarPanelModels.swift` as the pure formatting/state layer. Move EventKit permission and event loading into dedicated runtime types consumed by a single `CalendarPanelStore`, then keep `CalendarScreen.swift` focused on UI and web bridging. Treat macOS permission and integration behavior as valid only when launched as a real `.app` through Xcode or LaunchServices.

**Tech Stack:** SwiftUI, AppKit, EventKit, WebKit, Combine, Xcode project file, repo-local Swift script verification.

## Global Constraints

- Use `Quake4Mac.xcodeproj` and the existing `Quake4Mac` target; do not add a package manager.
- Preserve the fixed 1920x480 device UI assumptions and the existing `PanelWeb` touch-routing model.
- Keep Fantastical as an external launcher only; EventKit is the only event data source.
- Never request Calendar permission automatically at launch.
- Update generated Info.plist keys in `Quake4Mac.xcodeproj/project.pbxproj` if permission copy changes.
- For source changes, at minimum run `xcodebuild -project Quake4Mac.xcodeproj -scheme Quake4Mac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build`.

---

### Task 1: Lock In QA Rules And Test New Store Semantics

**Files:**
- Modify: `AGENTS.md`
- Modify: `scripts/calendar_logic_tests/main.swift`
- Create: `Quake4Mac/Home/CalendarStoreLogic.swift`

**Interfaces:**
- Consumes: `CalendarPanelStatus`, `CalendarPanelSnapshot`, `CalendarPanelEventSummary` from `Quake4Mac/Home/CalendarPanelModels.swift`
- Produces: `CalendarStoreLogic.snapshot(...)`, `CalendarStoreLogic.requestButtonTitle(for:)`, `CalendarStoreLogic.settingsAction(for:)`

- [ ] **Step 1: Write the failing test**

```swift
let notDeterminedSnapshot = CalendarStoreLogic.snapshot(
    status: .notDetermined,
    now: now,
    events: [],
    canOpenFantastical: true,
    calendar: calendar,
    locale: locale
)
require(notDeterminedSnapshot.message == "Grant Calendar access from Quake4Mac settings on your Mac", "notDetermined state points users to Mac-side settings")
require(CalendarStoreLogic.requestButtonTitle(for: .notDetermined) == "Grant Access", "settings CTA for notDetermined is explicit")
require(CalendarStoreLogic.settingsAction(for: .denied) == .openPrivacySettings, "denied state opens privacy settings")
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
CLANG_MODULE_CACHE_PATH=build/ModuleCache swiftc Quake4Mac/Home/CalendarPanelModels.swift Quake4Mac/Home/CalendarStoreLogic.swift scripts/calendar_logic_tests/main.swift -o build/TestProducts/quake-calendar-logic-tests
```

Expected: fail because `Quake4Mac/Home/CalendarStoreLogic.swift` does not exist yet and `CalendarStoreLogic` is undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

enum CalendarSettingsAction: Equatable {
    case requestAccess
    case openPrivacySettings
    case refreshEvents
}

enum CalendarStoreLogic {
    static func snapshot(status: CalendarPanelStatus, now: Date, events: [CalendarPanelEventSummary], canOpenFantastical: Bool, calendar: Calendar, locale: Locale) -> CalendarPanelSnapshot {
        let message: String
        switch status {
        case .authorized:
            message = events.isEmpty ? "No events today" : "\(events.count) event\(events.count == 1 ? "" : "s") today"
        case .notDetermined:
            message = "Grant Calendar access from Quake4Mac settings on your Mac"
        case .requesting:
            message = "Waiting for Calendar permission"
        case .denied:
            message = "Calendar access is off"
        case .restricted:
            message = "Calendar access is restricted"
        case .error:
            message = "Calendar status unavailable"
        }
        return CalendarPanelSnapshot(
            status: status,
            dateTitle: CalendarPanelLogic.dateTitle(for: now, calendar: calendar, locale: locale),
            message: message,
            events: events,
            canOpenFantastical: canOpenFantastical
        )
    }

    static func requestButtonTitle(for status: CalendarPanelStatus) -> String {
        switch status {
        case .authorized: return "Refresh Events"
        case .notDetermined: return "Grant Access"
        case .requesting: return "Requesting..."
        case .denied, .restricted: return "Open Privacy Settings"
        case .error: return "Try Again"
        }
    }

    static func settingsAction(for status: CalendarPanelStatus) -> CalendarSettingsAction {
        switch status {
        case .authorized, .error: return .refreshEvents
        case .notDetermined, .requesting: return .requestAccess
        case .denied, .restricted: return .openPrivacySettings
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
mkdir -p build/TestProducts
CLANG_MODULE_CACHE_PATH=build/ModuleCache swiftc Quake4Mac/Home/CalendarPanelModels.swift Quake4Mac/Home/CalendarStoreLogic.swift scripts/calendar_logic_tests/main.swift -o build/TestProducts/quake-calendar-logic-tests
build/TestProducts/quake-calendar-logic-tests
```

Expected: `PASS calendar logic`

- [ ] **Step 5: Commit**

```bash
git add AGENTS.md Quake4Mac/Home/CalendarStoreLogic.swift scripts/calendar_logic_tests/main.swift
git commit -m "test: lock calendar store semantics"
```

### Task 2: Extract Calendar Runtime Boundaries

**Files:**
- Create: `Quake4Mac/Home/CalendarServices.swift`
- Modify: `Quake4Mac/Home/CalendarScreen.swift`
- Modify: `Quake4Mac/App/Quake4MacApp.swift`
- Modify: `Quake4Mac.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `CalendarStoreLogic`, `CalendarPanelSnapshot`, `CalendarPanelEventSummary`
- Produces: `CalendarPermissionController`, `CalendarEventsService`, `FantasticalLauncher`, `CalendarPanelStore.shared`

- [ ] **Step 1: Write the failing test**

Add a store-level script assertion that the request path no longer maps `notDetermined` to an automatic launch bootstrap:

```swift
require(CalendarStoreLogic.settingsAction(for: .notDetermined) == .requestAccess, "notDetermined state requires explicit user request")
```

- [ ] **Step 2: Run test to verify it fails for the intended reason**

Run:

```bash
build/TestProducts/quake-calendar-logic-tests
```

Expected: FAIL until the new action semantics are present in the script and implementation.

- [ ] **Step 3: Write minimal implementation**

Create `Quake4Mac/Home/CalendarServices.swift` with the runtime types:

```swift
final class CalendarPermissionController {
    private let eventStore: EKEventStore
    private let workspace: NSWorkspace

    init(eventStore: EKEventStore, workspace: NSWorkspace = .shared) {
        self.eventStore = eventStore
        self.workspace = workspace
    }

    func status(requestingAccess: Bool) -> CalendarPanelStatus {
        let raw = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            switch raw {
            case .authorized, .fullAccess: return .authorized
            case .writeOnly, .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return requestingAccess ? .requesting : .notDetermined
            @unknown default: return .error
            }
        } else {
            switch raw {
            case .authorized: return .authorized
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return requestingAccess ? .requesting : .notDetermined
            @unknown default: return .error
            }
        }
    }

    func requestAccess(completion: @escaping (_ granted: Bool, _ errorMessage: String?) -> Void) {
        let handler: EKEventStoreRequestAccessCompletionHandler = { granted, error in
            DispatchQueue.main.async {
                completion(granted, error?.localizedDescription)
            }
        }
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToEvents(completion: handler)
        } else {
            eventStore.requestAccess(to: .event, completion: handler)
        }
    }

    func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") else { return }
        workspace.open(url)
    }
}

final class CalendarEventsService {
    private let eventStore: EKEventStore

    init(eventStore: EKEventStore) {
        self.eventStore = eventStore
    }

    func fetchEvents(for now: Date, hour24: Bool, calendar: Calendar, locale: Locale) -> [CalendarPanelEventSummary] {
        let interval = CalendarPanelLogic.dayInterval(containing: now, calendar: calendar)
        let predicate = eventStore.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        return CalendarPanelLogic.markRelativePositions(events: eventStore.events(matching: predicate)
            .sorted { lhs, rhs in
                if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay && !rhs.isAllDay }
                if lhs.startDate == rhs.startDate { return (lhs.title ?? "").localizedCaseInsensitiveCompare(rhs.title ?? "") == .orderedAscending }
                return lhs.startDate < rhs.startDate
            }
            .map { event in
                CalendarPanelEventSummary(
                    id: event.eventIdentifier ?? event.calendarItemIdentifier,
                    title: (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled event" : (event.title ?? ""),
                    startDate: event.startDate,
                    endDate: event.endDate,
                    isAllDay: event.isAllDay,
                    calendarName: event.calendar?.title ?? "Calendar",
                    calendarColorHex: CalendarColorMapper.hex(event.calendar?.cgColor),
                    location: event.location?.trimmingCharacters(in: .whitespacesAndNewlines),
                    timeText: CalendarPanelLogic.timeRangeText(start: event.startDate, end: event.endDate, isAllDay: event.isAllDay, calendar: calendar, locale: locale, hour24: hour24),
                    isNow: false,
                    isNext: false
                )
            }, now: now)
    }
}

final class CalendarPanelStore: ObservableObject {
    static let shared = CalendarPanelStore()
    @Published private(set) var snapshot: CalendarPanelSnapshot
    private let eventStore = EKEventStore()
    private lazy var permission = CalendarPermissionController(eventStore: eventStore)
    private lazy var eventsService = CalendarEventsService(eventStore: eventStore)
    private var refreshTimer: Timer?
    private var requestingAccess = false

    func start() {
        refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refresh() {
        let now = Date()
        let status = permission.status(requestingAccess: requestingAccess)
        let events = status == .authorized ? eventsService.fetchEvents(for: now, hour24: ClockStore.shared.hour24, calendar: .current, locale: .current) : []
        snapshot = CalendarStoreLogic.snapshot(
            status: status,
            now: now,
            events: events,
            canOpenFantastical: FantasticalLauncher.isInstalled,
            calendar: .current,
            locale: .current
        )
    }

    func requestAccess() {
        guard permission.status(requestingAccess: requestingAccess) == .notDetermined else {
            refresh()
            return
        }
        requestingAccess = true
        refresh()
        permission.requestAccess { [weak self] _, errorMessage in
            guard let self else { return }
            self.requestingAccess = false
            if let errorMessage {
                self.snapshot = CalendarStoreLogic.snapshot(
                    status: .error,
                    now: Date(),
                    events: [],
                    canOpenFantastical: FantasticalLauncher.isInstalled,
                    calendar: .current,
                    locale: .current
                )
                self.snapshot.message = errorMessage
            } else {
                self.refresh()
            }
        }
    }

    func openPrivacySettings() { permission.openPrivacySettings() }
}
```

Then refactor `CalendarScreen.swift` so:

```swift
private let store = CalendarPanelStore.shared
store.$snapshot
    .sink { [weak self] _ in self?.push() }
    .store(in: &bag)

if action == "openFantastical" { _ = FantasticalLauncher.open() }
else if action == "openCalendarPrivacy" { store.openPrivacySettings() }
else if action == "requestAccess" { store.requestAccess() }
```

And remove the launch bootstrap from `Quake4MacApp.swift`:

```swift
-        if prefs.bool(forKey: "calendar.requestAccessAtLaunch") {
-            prefs.removeObject(forKey: "calendar.requestAccessAtLaunch")
-            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
-                CalendarEventsStore.shared.requestCalendarAccess()
-            }
-        }
```

- [ ] **Step 4: Run verification**

Run:

```bash
CLANG_MODULE_CACHE_PATH=build/ModuleCache swiftc Quake4Mac/Home/CalendarPanelModels.swift Quake4Mac/Home/CalendarStoreLogic.swift scripts/calendar_logic_tests/main.swift -o build/TestProducts/quake-calendar-logic-tests
build/TestProducts/quake-calendar-logic-tests
xcodebuild -project Quake4Mac.xcodeproj -scheme Quake4Mac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

Expected: script prints `PASS calendar logic`; Xcode build ends with `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Quake4Mac/Home/CalendarServices.swift Quake4Mac/Home/CalendarScreen.swift Quake4Mac/App/Quake4MacApp.swift Quake4Mac.xcodeproj/project.pbxproj
git commit -m "refactor: split calendar runtime boundaries"
```

### Task 3: Rewire Settings And Device UI Around The New Store

**Files:**
- Modify: `Quake4Mac/Home/CalendarScreen.swift`
- Modify: `Quake4Mac/Web/calendar.html`

**Interfaces:**
- Consumes: `CalendarPanelStore.shared`, `CalendarStoreLogic.requestButtonTitle(for:)`, `CalendarStoreLogic.settingsAction(for:)`
- Produces: Mac-side settings actions that match the selected permission state, Quake panel copy that points users to the Mac-side settings flow

- [ ] **Step 1: Write the failing test**

Extend the script with copy expectations used by both surfaces:

```swift
let deniedSnapshot = CalendarStoreLogic.snapshot(
    status: .denied,
    now: now,
    events: [],
    canOpenFantastical: false,
    calendar: calendar,
    locale: locale
)
require(deniedSnapshot.message == "Calendar access is off", "denied state keeps the device copy short and explicit")
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
build/TestProducts/quake-calendar-logic-tests
```

Expected: FAIL until the shared snapshot logic returns the new copy.

- [ ] **Step 3: Write minimal implementation**

Update `CalendarPanelView` so the primary button dispatches through the new store action:

```swift
Button {
    switch CalendarStoreLogic.settingsAction(for: store.snapshot.status) {
    case .requestAccess:
        store.requestAccess()
    case .openPrivacySettings:
        store.openPrivacySettings()
    case .refreshEvents:
        store.refresh()
    }
} label: {
    Text(CalendarStoreLogic.requestButtonTitle(for: store.snapshot.status))
}
```

Update `Quake4Mac/Web/calendar.html` so the `notDetermined` state explains that access should be granted from Quake4Mac settings on the Mac, while `denied` and `restricted` still expose `Open Settings`.

- [ ] **Step 4: Run verification**

Run:

```bash
CLANG_MODULE_CACHE_PATH=build/ModuleCache swiftc Quake4Mac/Home/CalendarPanelModels.swift Quake4Mac/Home/CalendarStoreLogic.swift scripts/calendar_logic_tests/main.swift -o build/TestProducts/quake-calendar-logic-tests
build/TestProducts/quake-calendar-logic-tests
xcodebuild -project Quake4Mac.xcodeproj -scheme Quake4Mac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

Expected: `PASS calendar logic` and `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Quake4Mac/Home/CalendarScreen.swift Quake4Mac/Web/calendar.html scripts/calendar_logic_tests/main.swift
git commit -m "feat: align calendar ui with native permission flow"
```
