import Foundation
import EventKit
import AppKit
import Combine

// MARK: - Fantastical launcher

enum FantasticalLauncher {
    private static let bundleIDs = [
        "com.flexibits.fantastical2.mac",
        "com.flexibits.fantastical.mac",
        "com.flexibits.fantastical",
    ]

    static var applicationURL: URL? {
        bundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    static var isInstalled: Bool { applicationURL != nil }

    @discardableResult
    static func open() -> Bool {
        guard let url = applicationURL else { return false }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return true
    }
}

// MARK: - Permission controller

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
            case .authorized, .fullAccess:
                return .authorized
            case .writeOnly, .denied:
                return .denied
            case .restricted:
                return .restricted
            case .notDetermined:
                return requestingAccess ? .requesting : .notDetermined
            @unknown default:
                return .error
            }
        } else {
            switch raw {
            case .authorized, .fullAccess:
                return .authorized
            case .writeOnly, .denied:
                return .denied
            case .restricted:
                return .restricted
            case .notDetermined:
                return requestingAccess ? .requesting : .notDetermined
            @unknown default:
                return .error
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

// MARK: - Event queries

private enum CalendarColorMapper {
    static func hex(_ cgColor: CGColor?) -> String {
        guard let cgColor,
              let color = NSColor(cgColor: cgColor)?.usingColorSpace(.deviceRGB) else { return "#ff3b30" }
        let r = Int(round(color.redComponent * 255))
        let g = Int(round(color.greenComponent * 255))
        let b = Int(round(color.blueComponent * 255))
        return String(format: "#%02x%02x%02x", r, g, b)
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
        let events = eventStore.events(matching: predicate)
            .sorted { lhs, rhs in
                if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay && !rhs.isAllDay }
                if lhs.startDate == rhs.startDate {
                    return (lhs.title ?? "").localizedCaseInsensitiveCompare(rhs.title ?? "") == .orderedAscending
                }
                return lhs.startDate < rhs.startDate
            }
            .map { event in
                CalendarPanelEventSummary(
                    id: event.eventIdentifier ?? event.calendarItemIdentifier,
                    title: cleanedTitle(event.title),
                    startDate: event.startDate,
                    endDate: event.endDate,
                    isAllDay: event.isAllDay,
                    calendarName: event.calendar?.title ?? "Calendar",
                    calendarColorHex: CalendarColorMapper.hex(event.calendar?.cgColor),
                    location: cleanedLocation(event.location),
                    timeText: CalendarPanelLogic.timeRangeText(
                        start: event.startDate,
                        end: event.endDate,
                        isAllDay: event.isAllDay,
                        calendar: calendar,
                        locale: locale,
                        hour24: hour24
                    ),
                    isNow: false,
                    isNext: false
                )
            }

        return CalendarPanelLogic.markRelativePositions(events: events, now: now)
    }

    private func cleanedTitle(_ title: String?) -> String {
        let trimmed = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled event" : trimmed
    }

    private func cleanedLocation(_ location: String?) -> String? {
        let trimmed = (location ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Shared panel store

final class CalendarPanelStore: ObservableObject {
    static let shared = CalendarPanelStore()

    @Published private(set) var snapshot: CalendarPanelSnapshot

    private let eventStore: EKEventStore
    private let permission: CalendarPermissionController
    private let eventsService: CalendarEventsService
    private var refreshTimer: Timer?
    private var requestingAccess = false
    private var bag = Set<AnyCancellable>()
    private let refreshInterval: TimeInterval = 60

    private init(eventStore: EKEventStore = EKEventStore(), workspace: NSWorkspace = .shared) {
        self.eventStore = eventStore
        permission = CalendarPermissionController(eventStore: eventStore, workspace: workspace)
        eventsService = CalendarEventsService(eventStore: eventStore)

        let now = Date()
        snapshot = CalendarStoreLogic.snapshot(
            status: .notDetermined,
            now: now,
            events: [],
            canOpenFantastical: FantasticalLauncher.isInstalled,
            calendar: .current,
            locale: .current
        )

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &bag)

        NotificationCenter.default.publisher(for: .EKEventStoreChanged)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &bag)

        refresh()
    }

    func start() {
        refresh()
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
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

        if status == .authorized {
            let events = eventsService.fetchEvents(for: now, hour24: ClockStore.shared.hour24, calendar: .current, locale: .current)
            publish(status: .authorized, now: now, events: events)
        } else {
            publish(status: status, now: now)
        }
    }

    func requestAccess() {
        let status = permission.status(requestingAccess: requestingAccess)
        switch status {
        case .authorized:
            refresh()
        case .notDetermined:
            guard !requestingAccess else { return }
            requestingAccess = true
            publish(status: .requesting, now: Date())
            permission.requestAccess { [weak self] _, errorMessage in
                guard let self else { return }
                self.requestingAccess = false
                if let errorMessage, !errorMessage.isEmpty {
                    self.publish(status: .error, now: Date(), messageOverride: errorMessage)
                } else {
                    self.refresh()
                }
            }
        case .requesting:
            break
        case .denied, .restricted, .error:
            refresh()
        }
    }

    func openPrivacySettings() {
        permission.openPrivacySettings()
    }

    private func publish(
        status: CalendarPanelStatus,
        now: Date,
        events: [CalendarPanelEventSummary] = [],
        messageOverride: String? = nil
    ) {
        snapshot = CalendarStoreLogic.snapshot(
            status: status,
            now: now,
            events: events,
            canOpenFantastical: FantasticalLauncher.isInstalled,
            calendar: .current,
            locale: .current,
            messageOverride: messageOverride
        )
    }
}
