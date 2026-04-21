import SwiftUI
import WidgetKit

@main
struct CaloriesApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var session = SupabaseSessionStore.shared
    @Environment(\.scenePhase) private var scenePhase

    private let foodStore = FoodLogStore()
    private let favoritesStore = FavoritesStore()

    private func refreshWidgets() {
        WidgetCenter.shared.reloadTimelines(ofKind: "CaloriesMacrosWidget")
    }

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
                        await foodStore.hydrateRecentDaysFromCloud()
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
                            await foodStore.hydrateRecentDaysFromCloud()
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
                    refreshWidgets()
                }
                .onChange(of: settings.targetFat) { _, _ in
                    Task { await settings.syncGoalsToCloud() }
                    refreshWidgets()
                }
                .onChange(of: settings.targetCarbs) { _, _ in
                    Task { await settings.syncGoalsToCloud() }
                    refreshWidgets()
                }
                .onReceive(NotificationCenter.default.publisher(for: .foodLogDidChange)) { _ in
                    refreshWidgets()
                }
        }
    }
}
