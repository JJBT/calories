import SwiftUI

struct RootTabsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var showAddFood = false

    var body: some View {
        NavigationStack { HomeView() }
            .sheet(isPresented: $showAddFood) {
                AddFoodFlowView()
            }
            .onReceive(NotificationCenter.default.publisher(for: .presentAddFood)) { _ in
                showAddFood = true
            }
    }
}

#Preview {
    RootTabsView()
}
