import Foundation
import UIKit

struct ChatMessage: Identifiable, Equatable {
    enum Role: String, Codable {
        case user
        case assistant
        case system
    }

    let id: UUID
    let role: Role
    var text: String
    var images: [UIImage]
    var createdAt: Date
    var isPending: Bool

    init(id: UUID = UUID(), role: Role, text: String = "", images: [UIImage] = [], createdAt: Date = .now, isPending: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.images = images
        self.createdAt = createdAt
        self.isPending = isPending
    }
}

struct NutritionEstimate: Codable, Equatable {
    var title: String
    var amountText: String
    var calories: Double?
    var carbsG: Double?
    var proteinG: Double?
    var fatG: Double?
}

struct FoodEntry: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var calories: Double
    var protein: Double
    var fat: Double
    var carbs: Double
    var source: String?
    var createdAt: Date

    init(id: UUID = UUID(), name: String, calories: Double, protein: Double, fat: Double, carbs: Double, source: String? = nil, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.calories = calories
        self.protein = protein
        self.fat = fat
        self.carbs = carbs
        self.source = source
        self.createdAt = createdAt
    }
}

final class FoodLogStore {
    static let retentionMonths = 6
    private static var didAttemptLegacyMigration = false

    private let fileManager: FileManager
    private let calendar: Calendar

    init(fileManager: FileManager = .default, calendar: Calendar = .current) {
        self.fileManager = fileManager
        self.calendar = calendar
    }

    func dayKey(for date: Date) -> String {
        DayKey.from(date, calendar: calendar)
    }

    func load(dayKey: String, syncCloud: Bool = true) -> [FoodEntry] {
        migrateLegacyDataIfNeeded()
        pruneOldData()
        let local = loadLocalOnly(dayKey: dayKey)

        guard syncCloud else { return local }

        Task {
            if let cloud = await SupabaseREST.fetchFoodEntries(dayKey: dayKey) {
                // Re-read local state here to avoid resurrecting deleted entries.
                let latestLocal = self.loadLocalOnly(dayKey: dayKey)
                let hasLocalSnapshot = self.hasLocalSnapshot(dayKey: dayKey)

                // If there is no local file yet (fresh install / first open), hydrate from cloud.
                if !hasLocalSnapshot {
                    if cloud != latestLocal {
                        self.saveLocalOnly(cloud, dayKey: dayKey)
                        await MainActor.run {
                            NotificationCenter.default.post(name: .foodLogDidChange, object: nil)
                        }
                    }
                    return
                }

                // Local snapshot exists -> treat it as source of truth for this device/session.
                // This preserves deletes done locally while async cloud fetch is in flight.
                if latestLocal != cloud {
                    await SupabaseREST.replaceFoodEntries(dayKey: dayKey, entries: latestLocal)
                }
            }
        }

        return local
    }

    func save(_ entries: [FoodEntry], dayKey: String) {
        migrateLegacyDataIfNeeded()
        saveLocalOnly(entries, dayKey: dayKey)
        Task {
            await SupabaseREST.replaceFoodEntries(dayKey: dayKey, entries: entries)
        }
    }

    func syncAllLocalDaysToCloud() async {
        migrateLegacyDataIfNeeded()
        pruneOldData()
        guard let dir = try? baseDirURL(),
              let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }

        for file in files where file.pathExtension == "json" {
            let key = file.deletingPathExtension().lastPathComponent
            let local = loadLocalOnly(dayKey: key)
            let cloud = await SupabaseREST.fetchFoodEntries(dayKey: key) ?? []

            // Keep local snapshot authoritative to preserve local edits/deletes.
            if local != cloud {
                await SupabaseREST.replaceFoodEntries(dayKey: key, entries: local)
            }
        }

        await MainActor.run {
            NotificationCenter.default.post(name: .foodLogDidChange, object: nil)
        }
    }

    func hydrateRecentDaysFromCloud() async {
        migrateLegacyDataIfNeeded()
        pruneOldData()

        let today = calendar.startOfDay(for: .now)
        let cutoff = calendar.date(byAdding: .month, value: -Self.retentionMonths, to: today) ?? today
        let fromDayKey = dayKey(for: cutoff)

        guard let cloudByDay = await SupabaseREST.fetchFoodEntriesSince(dayKeyFrom: fromDayKey) else { return }

        for (dayKey, cloudEntries) in cloudByDay {
            // Existing local snapshot is treated as authoritative for this device.
            if hasLocalSnapshot(dayKey: dayKey) { continue }
            saveLocalOnly(cloudEntries, dayKey: dayKey)
        }

        await MainActor.run {
            NotificationCenter.default.post(name: .foodLogDidChange, object: nil)
        }
    }

    func loadAllLocalDays() -> [(dayKey: String, entries: [FoodEntry])] {
        migrateLegacyDataIfNeeded()
        pruneOldData()
        guard let dir = try? baseDirURL(),
              let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }

        var rows: [(dayKey: String, entries: [FoodEntry])] = []

        for file in files where file.pathExtension == "json" {
            let key = file.deletingPathExtension().lastPathComponent
            let parts = key.split(separator: "-")
            guard parts.count == 3,
                  Int(parts[0]) != nil, Int(parts[1]) != nil, Int(parts[2]) != nil else { continue }

            let entries = loadLocalOnly(dayKey: key).sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            if !entries.isEmpty {
                rows.append((dayKey: key, entries: entries))
            }
        }

        return rows.sorted { $0.dayKey < $1.dayKey }
    }

    private func loadLocalOnly(dayKey: String) -> [FoodEntry] {
        guard let url = try? entriesURL(dayKey: dayKey),
              fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([FoodEntry].self, from: data) else { return [] }
        return items
    }

    private func saveLocalOnly(_ entries: [FoodEntry], dayKey: String) {
        do {
            let url = try entriesURL(dayKey: dayKey)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entries)
            try data.write(to: url, options: [.atomic])
            pruneOldData()
        } catch {
            // no-op
        }
    }

    private func baseDirURL() throws -> URL {
        try SharedStorage.foodLogDirectory(fileManager: fileManager)
    }

    private func migrateLegacyDataIfNeeded() {
        guard !Self.didAttemptLegacyMigration else { return }
        Self.didAttemptLegacyMigration = true

        guard let sharedDir = try? baseDirURL(),
              let legacyDir = try? SharedStorage.legacyFoodLogDirectory(fileManager: fileManager) else { return }

        if sharedDir.standardizedFileURL == legacyDir.standardizedFileURL { return }
        guard fileManager.fileExists(atPath: legacyDir.path) else { return }

        do {
            try fileManager.createDirectory(at: sharedDir, withIntermediateDirectories: true)
            let legacyFiles = try fileManager.contentsOfDirectory(at: legacyDir, includingPropertiesForKeys: nil)

            for oldFile in legacyFiles where oldFile.pathExtension == "json" {
                let migratedFile = sharedDir.appendingPathComponent(oldFile.lastPathComponent)
                if fileManager.fileExists(atPath: migratedFile.path) { continue }
                try fileManager.copyItem(at: oldFile, to: migratedFile)
            }
        } catch {
            // no-op
        }
    }

    private func entriesURL(dayKey: String) throws -> URL {
        try baseDirURL().appendingPathComponent("\(dayKey).json")
    }

    private func hasLocalSnapshot(dayKey: String) -> Bool {
        guard let url = try? entriesURL(dayKey: dayKey) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    private func mergeEntries(local: [FoodEntry], cloud: [FoodEntry]) -> [FoodEntry] {
        var byId: [UUID: FoodEntry] = [:]

        for item in cloud {
            byId[item.id] = item
        }

        for item in local {
            if let existing = byId[item.id] {
                byId[item.id] = item.createdAt >= existing.createdAt ? item : existing
            } else {
                byId[item.id] = item
            }
        }

        return byId.values.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func pruneOldData(now: Date = .now) {
        guard let dir = try? baseDirURL(),
              let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }

        let today = calendar.startOfDay(for: now)
        let cutoff = calendar.date(byAdding: .month, value: -Self.retentionMonths, to: today) ?? today

        for file in files where file.pathExtension == "json" {
            let key = file.deletingPathExtension().lastPathComponent
            let parts = key.split(separator: "-")
            guard parts.count == 3,
                  let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
                  let date = calendar.date(from: DateComponents(year: y, month: m, day: d)) else { continue }
            if date < cutoff {
                try? fileManager.removeItem(at: file)
            }
        }
    }
}
