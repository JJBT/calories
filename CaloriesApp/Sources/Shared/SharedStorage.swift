import Foundation

enum SharedStorage {
    static let appGroupIdentifier = "group.dev.calories.calories1"

    static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    static func foodLogDirectory(fileManager: FileManager = .default) throws -> URL {
        if let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            return container
                .appendingPathComponent("Calories", isDirectory: true)
                .appendingPathComponent("foodlog", isDirectory: true)
        }

        return try legacyFoodLogDirectory(fileManager: fileManager)
    }

    static func legacyFoodLogDirectory(fileManager: FileManager = .default) throws -> URL {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support
            .appendingPathComponent("Calories", isDirectory: true)
            .appendingPathComponent("foodlog", isDirectory: true)
    }
}

enum SharedSettingsKey {
    static let localeId = "app.localeId"
    static let selectedDayTs = "app.selectedDayTs"
    static let targetProtein = "app.targetProtein"
    static let targetFat = "app.targetFat"
    static let targetCarbs = "app.targetCarbs"
    static let show7dAverage = "app.show7dAverage"
    static let fillBicepProgress = "app.fillBicepProgress"
    static let progressIcon = "app.progressIcon"
    static let themeMode = "app.themeMode"
}

enum DayKey {
    static func from(_ date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}
