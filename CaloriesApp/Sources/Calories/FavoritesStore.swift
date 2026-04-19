import Foundation

struct FavoriteFood: Identifiable, Codable, Equatable {
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

    init(entry: FoodEntry) {
        self.init(
            name: entry.name,
            calories: entry.calories,
            protein: entry.protein,
            fat: entry.fat,
            carbs: entry.carbs
        )
    }
}

final class FavoritesStore {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func load() -> [FavoriteFood] {
        let local = loadLocalOnly()

        Task {
            if let cloud = await SupabaseREST.fetchFavorites() {
                // Re-read local state to avoid resurrecting locally deleted favorites.
                let latestLocal = self.loadLocalOnly()
                let hasLocalSnapshot = self.hasLocalSnapshot()

                // Fresh install / first open: hydrate from cloud only if local snapshot does not exist yet.
                if !hasLocalSnapshot {
                    if cloud != latestLocal {
                        self.saveLocalOnly(cloud)
                        await MainActor.run {
                            NotificationCenter.default.post(name: .favoritesDidChange, object: nil)
                        }
                    }
                    return
                }

                // Local snapshot exists -> treat it as source of truth for this device/session.
                if latestLocal != cloud {
                    await SupabaseREST.replaceFavorites(latestLocal)
                }
            }
        }

        return local
    }

    @discardableResult
    func add(_ entry: FoodEntry) -> AddResult {
        var all = load()
        let sig = signature(name: entry.name, calories: entry.calories, protein: entry.protein, fat: entry.fat, carbs: entry.carbs)
        if all.contains(where: { signature(name: $0.name, calories: $0.calories, protein: $0.protein, fat: $0.fat, carbs: $0.carbs) == sig }) {
            return .alreadyExists
        }

        all.insert(FavoriteFood(entry: entry), at: 0)
        save(all)
        return .added
    }

    func remove(_ favorite: FavoriteFood) {
        var all = load()
        all.removeAll { $0.id == favorite.id }
        save(all)
    }

    func update(_ favorite: FavoriteFood) {
        var all = load()
        guard let idx = all.firstIndex(where: { $0.id == favorite.id }) else { return }
        all[idx] = favorite
        save(all)
    }

    func signature(name: String, calories: Double, protein: Double, fat: Double, carbs: Double) -> String {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(normalizedName)|\(Int(calories.rounded()))|\(Int(protein.rounded()))|\(Int(fat.rounded()))|\(Int(carbs.rounded()))"
    }

    enum AddResult {
        case added
        case alreadyExists
    }

    private func save(_ items: [FavoriteFood]) {
        saveLocalOnly(items)
        Task {
            await SupabaseREST.replaceFavorites(items)
        }
    }

    func syncLocalToCloud() async {
        let local = loadLocalOnly()
        let hasLocalSnapshot = hasLocalSnapshot()
        let cloud = await SupabaseREST.fetchFavorites() ?? []

        // If there is no local snapshot yet, seed local from cloud (first install/device).
        if !hasLocalSnapshot {
            if cloud != local {
                saveLocalOnly(cloud)
            }
        } else if local != cloud {
            // Existing local snapshot is authoritative.
            await SupabaseREST.replaceFavorites(local)
        }

        await MainActor.run {
            NotificationCenter.default.post(name: .favoritesDidChange, object: nil)
        }
    }

    private func loadLocalOnly() -> [FavoriteFood] {
        guard let url = try? favoritesURL(),
              fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([FavoriteFood].self, from: data) else { return [] }
        return items.sorted { $0.createdAt > $1.createdAt }
    }

    private func saveLocalOnly(_ items: [FavoriteFood]) {
        guard let url = try? favoritesURL() else { return }
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(items)
            try data.write(to: url, options: [.atomic])
        } catch {
            // no-op
        }
    }

    private func favoritesURL() throws -> URL {
        let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support
            .appendingPathComponent("Calories", isDirectory: true)
            .appendingPathComponent("favorites.json")
    }

    private func hasLocalSnapshot() -> Bool {
        guard let url = try? favoritesURL() else { return false }
        return fileManager.fileExists(atPath: url.path)
    }
}
