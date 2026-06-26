import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(("FAIL: \(message)\n").data(using: .utf8)!)
        exit(1)
    }
}

let iso = ISO8601DateFormatter()
iso.formatOptions = [.withInternetDateTime]

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(secondsFromGMT: 0)!
let locale = Locale(identifier: "en_US_POSIX")

let now = iso.date(from: "2026-06-25T10:30:00Z")!
let bounds = CalendarPanelLogic.dayInterval(containing: now, calendar: calendar)

require(bounds.start == iso.date(from: "2026-06-25T00:00:00Z")!, "day interval starts at local midnight")
require(bounds.end == iso.date(from: "2026-06-26T00:00:00Z")!, "day interval ends at next local midnight")

let allDayStart = iso.date(from: "2026-06-25T00:00:00Z")!
let allDayEnd = iso.date(from: "2026-06-26T00:00:00Z")!
let currentStart = iso.date(from: "2026-06-25T10:00:00Z")!
let currentEnd = iso.date(from: "2026-06-25T11:00:00Z")!
let nextStart = iso.date(from: "2026-06-25T13:00:00Z")!
let nextEnd = iso.date(from: "2026-06-25T14:00:00Z")!
let pastStart = iso.date(from: "2026-06-25T09:00:00Z")!
let pastEnd = iso.date(from: "2026-06-25T09:30:00Z")!

let events = [
    CalendarPanelEventSummary(id: "all-day", title: "Launch Day", startDate: allDayStart, endDate: allDayEnd, isAllDay: true, calendarName: "Work", calendarColorHex: "#ff3b30", location: nil, timeText: "All day", isNow: false, isNext: false),
    CalendarPanelEventSummary(id: "past", title: "Past Sync", startDate: pastStart, endDate: pastEnd, isAllDay: false, calendarName: "Work", calendarColorHex: "#ff3b30", location: nil, timeText: "09:00-09:30", isNow: false, isNext: false),
    CalendarPanelEventSummary(id: "current", title: "Current Standup", startDate: currentStart, endDate: currentEnd, isAllDay: false, calendarName: "Work", calendarColorHex: "#ff3b30", location: "Office", timeText: "10:00-11:00", isNow: false, isNext: false),
    CalendarPanelEventSummary(id: "next", title: "Design Review", startDate: nextStart, endDate: nextEnd, isAllDay: false, calendarName: "Work", calendarColorHex: "#ff3b30", location: nil, timeText: "13:00-14:00", isNow: false, isNext: false),
]

let marked = CalendarPanelLogic.markRelativePositions(events: events, now: now)
require(marked.first { $0.id == "current" }?.isNow == true, "current timed event is marked as now")
require(marked.first { $0.id == "next" }?.isNext == true, "first future timed event is marked as next")
require(marked.first { $0.id == "all-day" }?.isNow == false, "all-day event is not marked as now")
require(marked.first { $0.id == "all-day" }?.isNext == false, "all-day event is not marked as next")

let allDayText = CalendarPanelLogic.timeRangeText(start: allDayStart, end: allDayEnd, isAllDay: true, calendar: calendar, locale: locale, hour24: true)
let timedText = CalendarPanelLogic.timeRangeText(start: currentStart, end: currentEnd, isAllDay: false, calendar: calendar, locale: locale, hour24: true)

require(allDayText == "All day", "all-day time text is stable")
require(timedText == "10:00-11:00", "24-hour time range is stable")

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
require(CalendarStoreLogic.settingsAction(for: .notDetermined) == .requestAccess, "notDetermined state requires explicit user request")
require(CalendarStoreLogic.settingsAction(for: .denied) == .openPrivacySettings, "denied state opens privacy settings")
require(HomeLayoutMigration.shouldAddFantastical(hasMigrationRun: false, destKeys: [["panel:clock"]]) == true, "existing layouts get one Fantastical migration")
require(HomeLayoutMigration.shouldAddFantastical(hasMigrationRun: true, destKeys: [["panel:clock"]]) == false, "user removal is respected after migration ran")
require(HomeLayoutMigration.shouldAddFantastical(hasMigrationRun: false, destKeys: [["panel:calendar"]]) == false, "existing Fantastical app is not duplicated")
require(CalendarAppLabels.appTitle == "Calendar", "home app uses the generic Calendar label")
require(CalendarAppLabels.panelTitle == "Calendar", "device panel uses the generic Calendar label")
require(CalendarAppLabels.settingsTitle == "Calendar", "settings panel uses the generic Calendar label")
require(CalendarAppLabels.externalOpenTitle == "Open Fantastical", "external handoff still names Fantastical")

let calendarServicesSource = try String(contentsOfFile: "Quake4Mac/Home/CalendarServices.swift", encoding: .utf8)
require(calendarServicesSource.contains("EKEventStoreChanged"), "calendar store refreshes when EventKit reports store changes")

let deniedSnapshot = CalendarStoreLogic.snapshot(
    status: .denied,
    now: now,
    events: [],
    canOpenFantastical: false,
    calendar: calendar,
    locale: locale
)
require(deniedSnapshot.message == "Calendar access is off", "denied state keeps the device copy short and explicit")

print("PASS calendar logic")
