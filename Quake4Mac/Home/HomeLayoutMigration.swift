import Foundation

enum HomeLayoutMigration {
    static let fantasticalMigrationKey = "home.migration.fantasticalCalendarAdded"
    static let fantasticalDestKey = "panel:calendar"

    static func shouldAddFantastical(hasMigrationRun: Bool, destKeys: [[String]]) -> Bool {
        !hasMigrationRun && !containsFantastical(destKeys: destKeys)
    }

    static func containsFantastical(destKeys: [[String]]) -> Bool {
        destKeys.flatMap { $0 }.contains(fantasticalDestKey)
    }
}
