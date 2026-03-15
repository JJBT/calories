import SwiftUI
import UIKit

extension Color {
    static let appBackground = Color(uiColor: .systemBackground)
    static let appSurface = Color(uiColor: .secondarySystemBackground)
    static let appSurfaceElevated = Color(uiColor: .tertiarySystemBackground)

    static let appTextPrimary = Color(uiColor: .label)
    static let appTextSecondary = Color(uiColor: .secondaryLabel)
    static let appTextTertiary = Color(uiColor: .tertiaryLabel)

    static let appBubbleUser = Color(uiColor: .label)
    static let appBubbleAssistant = Color(uiColor: .secondarySystemBackground)
}

@main
struct CaloriesApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var session = SupabaseSessionStore.shared
    @Environment(\.scenePhase) private var scenePhase

    private let foodStore = FoodLogStore()
    private let favoritesStore = FavoritesStore()

    var body: some Scene {
        WindowGroup {
            RootTabsView()
                .environmentObject(settings)
                .environmentObject(session)
                .environment(\.locale, settings.locale)
                .preferredColorScheme(settings.themeMode.colorScheme)
                .task {
                    await session.validateCurrentSession()
                    await settings.ensureProfileDefaultsInCloud()
                    await settings.syncGoalsFromCloudIfAvailable()
                    if session.isAuthenticated {
                        await foodStore.syncAllLocalDaysToCloud()
                        await favoritesStore.syncLocalToCloud()
                    }
                    NotificationCenter.default.post(name: .foodLogDidChange, object: nil)
                    NotificationCenter.default.post(name: .favoritesDidChange, object: nil)
                }
                .onReceive(NotificationCenter.default.publisher(for: .supabaseSessionDidChange)) { _ in
                    Task {
                        await settings.ensureProfileDefaultsInCloud()
                        await settings.syncGoalsFromCloudIfAvailable()
                        if session.isAuthenticated {
                            await foodStore.syncAllLocalDaysToCloud()
                            await favoritesStore.syncLocalToCloud()
                        }
                        NotificationCenter.default.post(name: .foodLogDidChange, object: nil)
                        NotificationCenter.default.post(name: .favoritesDidChange, object: nil)
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task {
                        await session.validateCurrentSession()
                        NotificationCenter.default.post(name: .foodLogDidChange, object: nil)
                        NotificationCenter.default.post(name: .favoritesDidChange, object: nil)
                    }
                }
                .onChange(of: settings.targetProtein) { _, _ in
                    Task { await settings.syncGoalsToCloud() }
                }
                .onChange(of: settings.targetFat) { _, _ in
                    Task { await settings.syncGoalsToCloud() }
                }
                .onChange(of: settings.targetCarbs) { _, _ in
                    Task { await settings.syncGoalsToCloud() }
                }
        }
    }
}
