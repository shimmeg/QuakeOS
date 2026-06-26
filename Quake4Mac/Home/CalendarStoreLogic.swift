import Foundation

enum CalendarSettingsAction: Equatable {
    case requestAccess
    case openPrivacySettings
    case refreshEvents
}

enum CalendarStoreLogic {
    static func snapshot(
        status: CalendarPanelStatus,
        now: Date,
        events: [CalendarPanelEventSummary],
        canOpenFantastical: Bool,
        calendar: Calendar,
        locale: Locale,
        messageOverride: String? = nil
    ) -> CalendarPanelSnapshot {
        CalendarPanelSnapshot(
            status: status,
            dateTitle: CalendarPanelLogic.dateTitle(for: now, calendar: calendar, locale: locale),
            message: messageOverride ?? defaultMessage(status: status, eventCount: events.count),
            events: events,
            canOpenFantastical: canOpenFantastical
        )
    }

    static func requestButtonTitle(for status: CalendarPanelStatus) -> String {
        switch status {
        case .authorized:
            return "Refresh Events"
        case .notDetermined:
            return "Grant Access"
        case .requesting:
            return "Requesting..."
        case .denied, .restricted:
            return "Open Privacy Settings"
        case .error:
            return "Try Again"
        }
    }

    static func settingsAction(for status: CalendarPanelStatus) -> CalendarSettingsAction {
        switch status {
        case .notDetermined, .requesting:
            return .requestAccess
        case .denied, .restricted:
            return .openPrivacySettings
        case .authorized, .error:
            return .refreshEvents
        }
    }

    static func defaultMessage(status: CalendarPanelStatus, eventCount: Int) -> String {
        switch status {
        case .authorized:
            return eventCount == 0 ? "No events today" : "\(eventCount) event\(eventCount == 1 ? "" : "s") today"
        case .notDetermined:
            return "Grant Calendar access from Quake4Mac settings on your Mac"
        case .requesting:
            return "Waiting for Calendar permission"
        case .denied:
            return "Calendar access is off"
        case .restricted:
            return "Calendar access is restricted"
        case .error:
            return "Calendar status unavailable"
        }
    }
}
