import SwiftUI
import UIKit

struct AddFoodFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: FoodChatView.ContentTab = .chat
    @State private var recentSearchText: String = ""
    @State private var favoritesSearchText: String = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                FoodChatView(
                    embedded: true,
                    selectedTabBinding: $selectedTab,
                    recentSearchTextBinding: $recentSearchText,
                    favoritesSearchTextBinding: $favoritesSearchText
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                if searchFocused {
                    searchFocused = false
                    hideKeyboard()
                }
            }
        )
        .onChange(of: selectedTab) { _, newTab in
            if newTab != .recent && newTab != .favorites {
                searchFocused = false
                hideKeyboard()
            }
        }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private var header: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width - 32 // header horizontal paddings
            let showsSearch = selectedTab == .recent || selectedTab == .favorites
            let closeVisible = !showsSearch || !searchFocused
            let closeWidth: CGFloat = closeVisible ? 40 : 0
            let spacing: CGFloat = closeVisible && showsSearch ? 10 : 0
            let availableForSearch = max(140, totalWidth - closeWidth - spacing)
            let searchWidth = showsSearch
                ? (searchFocused ? totalWidth : availableForSearch)
                : 0
            let searchBinding = Binding<String>(
                get: { selectedTab == .favorites ? favoritesSearchText : recentSearchText },
                set: {
                    if selectedTab == .favorites {
                        favoritesSearchText = $0
                    } else {
                        recentSearchText = $0
                    }
                }
            )

            HStack(spacing: spacing) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.appTextPrimary)
                        .frame(width: 40, height: 40)
                        .background(Color.appSurface, in: Circle())
                }
                .frame(width: closeWidth, height: 40, alignment: .leading)
                .opacity(closeWidth > 0 ? 1 : 0)
                .allowsHitTesting(closeWidth > 0)

                if showsSearch {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.appTextPrimary)

                        TextField(selectedTab == .favorites ? "Поиск в избранном" : "Поиск в недавнем", text: searchBinding)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(Color.appTextPrimary)
                            .focused($searchFocused)

                        if !searchBinding.wrappedValue.isEmpty {
                            Button {
                                searchBinding.wrappedValue = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.appTextTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(width: searchWidth, height: 40)
                    .background(Color.appSurface, in: Capsule())
                    .contentShape(Capsule())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                            searchFocused = true
                        }
                    }
                } else {
                    Spacer()
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.88), value: searchFocused)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)
        }
        .frame(height: 64)
    }
}

#Preview {
    AddFoodFlowView()
}
