import Foundation
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    enum ThemeMode: String, CaseIterable {
        case system
        case light
        case dark

        var title: String {
            switch self {
            case .system: return "Системная"
            case .light: return "Светлая"
            case .dark: return "Тёмная"
            }
        }

        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    @AppStorage("app.localeId") var localeId: String = "ru" // пока оставлено для совместимости

    /// Выбранный день для UI и логирования.
    /// Храним как timeInterval (Double), чтобы работало с AppStorage.
    @AppStorage("app.selectedDayTs") private var selectedDayTs: Double = Date.now.timeIntervalSince1970

    @AppStorage("app.targetProtein") var targetProtein: Double = 158
    @AppStorage("app.targetFat") var targetFat: Double = 58
    @AppStorage("app.targetCarbs") var targetCarbs: Double = 236
    enum ProgressIcon: String, CaseIterable {
        case strength
        case flame
        case bolt
        case target
        case leaf

        var title: String {
            switch self {
            case .strength: return "Тренировка"
            case .flame: return "Огонь"
            case .bolt: return "Молния"
            case .target: return "Цель"
            case .leaf: return "Лист"
            }
        }

        var symbolName: String {
            switch self {
            case .strength: return "figure.strengthtraining.traditional"
            case .flame: return "flame.fill"
            case .bolt: return "bolt.fill"
            case .target: return "target"
            case .leaf: return "leaf.fill"
            }
        }
    }

    @AppStorage("app.show7dAverage") var show7dAverage: Bool = true
    @AppStorage("app.fillBicepProgress") var fillBicepProgress: Bool = true
    @AppStorage("app.progressIcon") var progressIconRaw: String = ProgressIcon.strength.rawValue
    @AppStorage("app.themeMode") var themeModeRaw: String = ThemeMode.system.rawValue

    var locale: Locale { Locale(identifier: localeId) }

    var selectedDay: Date {
        get { Date(timeIntervalSince1970: selectedDayTs) }
        set { selectedDayTs = newValue.timeIntervalSince1970 }
    }

    var themeMode: ThemeMode {
        get { ThemeMode(rawValue: themeModeRaw) ?? .system }
        set { themeModeRaw = newValue.rawValue }
    }

    var progressIcon: ProgressIcon {
        get { ProgressIcon(rawValue: progressIconRaw) ?? .strength }
        set { progressIconRaw = newValue.rawValue }
    }

    var targetCalories: Int {
        let raw = targetProtein * 4 + targetFat * 9 + targetCarbs * 4
        return Int((raw / 10).rounded() * 10)
    }

    func syncGoalsFromCloudIfAvailable() async {
        guard let goals = await SupabaseREST.fetchProfileGoals() else { return }
        if goals.protein > 0 { targetProtein = goals.protein }
        if goals.fat > 0 { targetFat = goals.fat }
        if goals.carbs > 0 { targetCarbs = goals.carbs }
    }

    func syncGoalsToCloud() async {
        await SupabaseREST.upsertProfileGoals(protein: targetProtein, fat: targetFat, carbs: targetCarbs)
    }

    func ensureProfileDefaultsInCloud() async {
        await SupabaseREST.ensureProfileGoalsExist(
            defaultProtein: targetProtein,
            defaultFat: targetFat,
            defaultCarbs: targetCarbs
        )
    }
}
