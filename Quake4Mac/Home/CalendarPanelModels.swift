import Foundation

enum CalendarPanelStatus: String {
    case notDetermined
    case requesting
    case authorized
    case denied
    case restricted
    case error
}

struct CalendarPanelEventSummary: Equatable {
    var id: String
    var title: String
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    var calendarName: String
    var calendarColorHex: String
    var location: String?
    var timeText: String
    var isNow: Bool
    var isNext: Bool

    var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "id": id,
            "title": title,
            "start": startDate.timeIntervalSince1970,
            "end": endDate.timeIntervalSince1970,
            "isAllDay": isAllDay,
            "calendarName": calendarName,
            "calendarColorHex": calendarColorHex,
            "timeText": timeText,
            "isNow": isNow,
            "isNext": isNext,
        ]
        if let location, !location.isEmpty { object["location"] = location }
        return object
    }
}

struct CalendarPanelSnapshot {
    var status: CalendarPanelStatus
    var dateTitle: String
    var message: String
    var events: [CalendarPanelEventSummary]
    var canOpenFantastical: Bool

    var jsonObject: [String: Any] {
        [
            "status": status.rawValue,
            "dateTitle": dateTitle,
            "message": message,
            "events": events.map { $0.jsonObject },
            "canOpenFantastical": canOpenFantastical,
        ]
    }
}

enum CalendarPanelLogic {
    static func dayInterval(containing date: Date, calendar: Calendar) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return DateInterval(start: start, end: end)
    }

    static func markRelativePositions(events: [CalendarPanelEventSummary], now: Date) -> [CalendarPanelEventSummary] {
        let nextID = events
            .filter { !$0.isAllDay && $0.startDate > now }
            .sorted { lhs, rhs in
                if lhs.startDate == rhs.startDate { return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending }
                return lhs.startDate < rhs.startDate
            }
            .first?.id

        return events.map { event in
            var event = event
            event.isNow = !event.isAllDay && event.startDate <= now && event.endDate > now
            event.isNext = event.id == nextID
            return event
        }
    }

    static func timeRangeText(start: Date, end: Date, isAllDay: Bool, calendar: Calendar, locale: Locale, hour24: Bool) -> String {
        guard !isAllDay else { return "All day" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = hour24 ? "HH:mm" : "h:mm a"
        return "\(formatter.string(from: start))-\(formatter.string(from: end))"
    }

    static func dateTitle(for date: Date, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE, MMM d"
        return formatter.string(from: date)
    }
}
