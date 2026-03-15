import Foundation

struct FoodEntry: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var calories: Double
    var protein: Double
    var fat: Double
    var carbs: Double
    var createdAt: Date

    init(id: UUID = UUID(), name: String, calories: Double, protein: Double, fat: Double, carbs: Double, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.calories = calories
        self.protein = protein
        self.fat = fat
        self.carbs = carbs
        self.createdAt = createdAt
    }
}

final class FoodLogStore {
    private let fileManager: FileManager
    private let calendar: Calendar

    init(fileManager: FileManager = .default, calendar: Calendar = .current) {
        self.fileManager = fileManager
        self.calendar = calendar
    }

    func dayKey(for date: Date) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    func load(dayKey: String) -> [FoodEntry] {
        guard let url = try? entriesURL(dayKey: dayKey),
              fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([FoodEntry].self, from: data) else { return [] }
        return items
    }

    func save(_ entries: [FoodEntry], dayKey: String) {
        do {
            let url = try entriesURL(dayKey: dayKey)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entries)
            try data.write(to: url, options: [.atomic])
        } catch {
            // no-op
        }
    }

    private func baseDirURL() throws -> URL {
        let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appendingPathComponent("Calories", isDirectory: true).appendingPathComponent("foodlog", isDirectory: true)
    }

    private func entriesURL(dayKey: String) throws -> URL {
        try baseDirURL().appendingPathComponent("\(dayKey).json")
    }
}
