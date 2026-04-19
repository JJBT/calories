import Foundation

enum SupabaseREST {
    static func replaceFoodEntries(dayKey: String, entries: [FoodEntry]) async {
        guard let ctx = context else { return }

        do {
            // 1) Fetch existing IDs for this day.
            let existingData = try await request(
                path: "/rest/v1/food_entries?user_id=eq.\(ctx.userId)&eaten_on=eq.\(dayKey)&select=id",
                method: "GET",
                body: nil,
                prefer: nil,
                context: ctx
            )
            let existingRows = try JSONDecoder().decode([IDRow].self, from: existingData)
            let existingIDs = Set(existingRows.map { $0.id.uuidString.lowercased() })

            // 2) Upsert current entries (no transient zero window).
            let newIDs = Set(entries.map { $0.id.uuidString.lowercased() })
            if !entries.isEmpty {
                let payload: [[String: Any]] = entries.map {
                    [
                        "id": $0.id.uuidString.lowercased(),
                        "user_id": ctx.userId,
                        "eaten_on": dayKey,
                        "name": $0.name,
                        "calories": $0.calories,
                        "protein": $0.protein,
                        "fat": $0.fat,
                        "carbs": $0.carbs,
                        "source": $0.source as Any,
                        "created_at": iso8601($0.createdAt)
                    ]
                }
                _ = try await request(
                    path: "/rest/v1/food_entries",
                    method: "POST",
                    body: payload,
                    prefer: "resolution=merge-duplicates,return=minimal",
                    context: ctx
                )
            }

            // 3) Delete stale rows that are no longer in the day snapshot.
            let staleIDs = existingIDs.subtracting(newIDs)
            if !staleIDs.isEmpty {
                let csv = staleIDs.joined(separator: ",")
                _ = try await request(
                    path: "/rest/v1/food_entries?user_id=eq.\(ctx.userId)&eaten_on=eq.\(dayKey)&id=in.(\(csv))",
                    method: "DELETE",
                    body: nil,
                    prefer: nil,
                    context: ctx
                )
            }

            // Keep cloud table compact: remove food entries older than retention window for this user.
            let cutoff = dayKeyKeepingLastRetentionWindow()
            _ = try await request(
                path: "/rest/v1/food_entries?user_id=eq.\(ctx.userId)&eaten_on=lt.\(cutoff)",
                method: "DELETE",
                body: nil,
                prefer: nil,
                context: ctx
            )
        } catch {
            // keep local data if cloud fails
        }
    }

    static func fetchFoodEntries(dayKey: String) async -> [FoodEntry]? {
        guard let ctx = context else { return nil }
        do {
            let data = try await request(
                path: "/rest/v1/food_entries?user_id=eq.\(ctx.userId)&eaten_on=eq.\(dayKey)&select=id,name,calories,protein,fat,carbs,source,created_at&order=created_at.asc",
                method: "GET",
                body: nil,
                prefer: nil,
                context: ctx
            )
            let rows = try makeDecoder().decode([FoodRow].self, from: data)
            return rows.map { $0.toEntry }
        } catch {
            return nil
        }
    }

    static func replaceFavorites(_ favorites: [FavoriteFood]) async {
        guard let ctx = context else { return }
        do {
            let existingData = try await request(
                path: "/rest/v1/favorites?user_id=eq.\(ctx.userId)&select=id",
                method: "GET",
                body: nil,
                prefer: nil,
                context: ctx
            )
            let existingRows = try JSONDecoder().decode([IDRow].self, from: existingData)
            let existingIDs = Set(existingRows.map { $0.id.uuidString.lowercased() })

            let newIDs = Set(favorites.map { $0.id.uuidString.lowercased() })
            if !favorites.isEmpty {
                let payload: [[String: Any]] = favorites.map {
                    [
                        "id": $0.id.uuidString.lowercased(),
                        "user_id": ctx.userId,
                        "signature": FavoritesStore().signature(name: $0.name, calories: $0.calories, protein: $0.protein, fat: $0.fat, carbs: $0.carbs),
                        "name": $0.name,
                        "calories": $0.calories,
                        "protein": $0.protein,
                        "fat": $0.fat,
                        "carbs": $0.carbs,
                        "created_at": iso8601($0.createdAt)
                    ]
                }
                _ = try await request(
                    path: "/rest/v1/favorites",
                    method: "POST",
                    body: payload,
                    prefer: "resolution=merge-duplicates,return=minimal",
                    context: ctx
                )
            }

            let staleIDs = existingIDs.subtracting(newIDs)
            if !staleIDs.isEmpty {
                let csv = staleIDs.joined(separator: ",")
                _ = try await request(
                    path: "/rest/v1/favorites?user_id=eq.\(ctx.userId)&id=in.(\(csv))",
                    method: "DELETE",
                    body: nil,
                    prefer: nil,
                    context: ctx
                )
            }
        } catch {}
    }

    static func fetchFavorites() async -> [FavoriteFood]? {
        guard let ctx = context else { return nil }
        do {
            let data = try await request(
                path: "/rest/v1/favorites?user_id=eq.\(ctx.userId)&select=id,name,calories,protein,fat,carbs,created_at&order=created_at.desc",
                method: "GET",
                body: nil,
                prefer: nil,
                context: ctx
            )
            let rows = try makeDecoder().decode([FavoriteRow].self, from: data)
            return rows.map { $0.toFavorite }
        } catch {
            return nil
        }
    }

    static func fetchProfileGoals() async -> ProfileGoals? {
        guard let ctx = context else { return nil }
        do {
            let data = try await request(
                path: "/rest/v1/profiles?user_id=eq.\(ctx.userId)&select=daily_protein_goal,daily_fat_goal,daily_carbs_goal&limit=1",
                method: "GET",
                body: nil,
                prefer: nil,
                context: ctx
            )
            let rows = try JSONDecoder().decode([ProfileGoalsRow].self, from: data)
            guard let row = rows.first else { return nil }
            return ProfileGoals(
                protein: Double(row.daily_protein_goal ?? 0),
                fat: Double(row.daily_fat_goal ?? 0),
                carbs: Double(row.daily_carbs_goal ?? 0)
            )
        } catch {
            return nil
        }
    }

    static func upsertProfileGoals(protein: Double, fat: Double, carbs: Double) async {
        guard let ctx = context else { return }
        let payload: [String: Any] = [
            "user_id": ctx.userId,
            "daily_protein_goal": Int(protein.rounded()),
            "daily_fat_goal": Int(fat.rounded()),
            "daily_carbs_goal": Int(carbs.rounded()),
            "daily_calorie_goal": Int((protein * 4 + fat * 9 + carbs * 4).rounded())
        ]

        do {
            _ = try await request(
                path: "/rest/v1/profiles",
                method: "POST",
                body: [payload],
                prefer: "resolution=merge-duplicates,return=minimal",
                context: ctx
            )
        } catch {
            // keep local settings if cloud upsert fails
        }
    }

    static func ensureProfileGoalsExist(defaultProtein: Double, defaultFat: Double, defaultCarbs: Double) async {
        guard let ctx = context else { return }

        let payload: [String: Any] = [
            "user_id": ctx.userId,
            "daily_protein_goal": Int(defaultProtein.rounded()),
            "daily_fat_goal": Int(defaultFat.rounded()),
            "daily_carbs_goal": Int(defaultCarbs.rounded()),
            "daily_calorie_goal": Int((defaultProtein * 4 + defaultFat * 9 + defaultCarbs * 4).rounded())
        ]

        do {
            // Insert defaults only for brand new profile; keep existing rows untouched.
            _ = try await request(
                path: "/rest/v1/profiles?on_conflict=user_id",
                method: "POST",
                body: [payload],
                prefer: "resolution=ignore-duplicates,return=minimal",
                context: ctx
            )
        } catch {
            // no-op
        }
    }

    private static var context: RequestContext? {
        guard let baseURL = SupabaseConfig.projectURL,
              !SupabaseConfig.publishableKey.isEmpty else { return nil }
        let defaults = UserDefaults.standard
        guard let token = defaults.string(forKey: "supabase.accessToken"), !token.isEmpty,
              let userId = defaults.string(forKey: "supabase.userId"), !userId.isEmpty else { return nil }
        return RequestContext(baseURL: baseURL, apiKey: SupabaseConfig.publishableKey, accessToken: token, userId: userId)
    }

    private static func request(path: String, method: String, body: Any?, prefer: String?, context: RequestContext) async throws -> Data {
        guard let url = URL(string: path, relativeTo: context.baseURL) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(context.apiKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(context.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let prefer { req.setValue(prefer, forHTTPHeaderField: "Prefer") }

        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "SupabaseREST", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "Request failed"])
        }
        return data
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { container in
            let raw = try container.singleValueContainer().decode(String.self)
            if let d = iso8601WithFractional.date(from: raw) { return d }
            if let d = iso8601Plain.date(from: raw) { return d }
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: container.codingPath, debugDescription: "Invalid ISO8601 date: \(raw)")
            )
        }
        return decoder
    }

    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601Plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func dayKeyKeepingLastRetentionWindow(now: Date = .now) -> String {
        let cal = Calendar.current
        let start = cal.startOfDay(for: now)
        let cutoffDate = cal.date(byAdding: .month, value: -FoodLogStore.retentionMonths, to: start) ?? start
        let comps = cal.dateComponents([.year, .month, .day], from: cutoffDate)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    struct ProfileGoals: Sendable {
        let protein: Double
        let fat: Double
        let carbs: Double
    }

    private struct RequestContext {
        let baseURL: URL
        let apiKey: String
        let accessToken: String
        let userId: String
    }

    private struct FoodRow: Decodable {
        let id: UUID
        let name: String
        let calories: Double
        let protein: Double
        let fat: Double
        let carbs: Double
        let source: String?
        let created_at: Date

        var toEntry: FoodEntry {
            FoodEntry(id: id, name: name, calories: calories, protein: protein, fat: fat, carbs: carbs, source: source, createdAt: created_at)
        }
    }

    private struct FavoriteRow: Decodable {
        let id: UUID
        let name: String
        let calories: Double
        let protein: Double
        let fat: Double
        let carbs: Double
        let created_at: Date

        var toFavorite: FavoriteFood {
            FavoriteFood(id: id, name: name, calories: calories, protein: protein, fat: fat, carbs: carbs, createdAt: created_at)
        }
    }

    private struct ProfileGoalsRow: Decodable {
        let daily_protein_goal: Int?
        let daily_fat_goal: Int?
        let daily_carbs_goal: Int?
    }

    private struct IDRow: Decodable {
        let id: UUID
    }
}
