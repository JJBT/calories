import SwiftUI
import Photos
import UIKit

struct FoodChatView: View {
    enum ContentTab: String {
        case chat = "Чат"
        case favorites = "Избранное"
        case recent = "Недавние"
    }

    var embedded: Bool = false

    @EnvironmentObject private var settings: AppSettings
    @StateObject private var vm: FoodChatViewModel

    @MainActor
    init(
        embedded: Bool = false,
        viewModel: FoodChatViewModel? = nil,
        selectedTabBinding: Binding<ContentTab>? = nil,
        recentSearchTextBinding: Binding<String>? = nil,
        favoritesSearchTextBinding: Binding<String>? = nil
    ) {
        self.embedded = embedded
        self.selectedTabBinding = selectedTabBinding
        self.recentSearchTextBinding = recentSearchTextBinding
        self.favoritesSearchTextBinding = favoritesSearchTextBinding
        _vm = StateObject(wrappedValue: viewModel ?? .shared)
    }

    @State private var showPicker = false
    @State private var showCamera = false
    @State private var previewItem: PreviewImageItem?
    @State private var toastText: String?
    @State private var selectedTabState: ContentTab = .chat
    @State private var recentEntries: [FoodEntry] = []
    @State private var favoriteEntries: [FavoriteFood] = []
    @State private var recentSearchTextState: String = ""
    @State private var favoritesSearchTextState: String = ""
    @State private var addDayCandidate: FoodEntry?
    @State private var removeFavoriteCandidate: FavoriteFood?
    @State private var editFavoriteCandidate: FavoriteFood?

    var selectedTabBinding: Binding<ContentTab>?
    var recentSearchTextBinding: Binding<String>?
    var favoritesSearchTextBinding: Binding<String>?

    @State private var editingDraftImageIndex: Int?
    @State private var isKeyboardVisible = false
    @FocusState private var isComposerFocused: Bool

    private let foodStore = FoodLogStore()
    private let favoritesStore = FavoritesStore()

    private var editingDraftImage: UIImage? {
        guard let idx = editingDraftImageIndex,
              vm.composerImages.indices.contains(idx) else { return nil }
        return vm.composerImages[idx]
    }

    private var selectedTab: ContentTab {
        selectedTabBinding?.wrappedValue ?? selectedTabState
    }

    private func setSelectedTab(_ tab: ContentTab) {
        if let selectedTabBinding {
            selectedTabBinding.wrappedValue = tab
        } else {
            selectedTabState = tab
        }
    }

    private var recentSearchText: String {
        recentSearchTextBinding?.wrappedValue ?? recentSearchTextState
    }

    private func setRecentSearchText(_ value: String) {
        if let recentSearchTextBinding {
            recentSearchTextBinding.wrappedValue = value
        } else {
            recentSearchTextState = value
        }
    }

    private var favoritesSearchText: String {
        favoritesSearchTextBinding?.wrappedValue ?? favoritesSearchTextState
    }

    private func setFavoritesSearchText(_ value: String) {
        if let favoritesSearchTextBinding {
            favoritesSearchTextBinding.wrappedValue = value
        } else {
            favoritesSearchTextState = value
        }
    }

    private func dismissKeyboard() {
        isComposerFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                if !embedded {
                    header
                    Divider().opacity(0.2)
                } else {
                    Spacer().frame(height: 6)
                }
                contentArea

                if selectedTab == .chat {
                    composer
                }

                if !(selectedTab == .chat && isKeyboardVisible) {
                    modeTabs
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            vm.ensureLoaded(for: settings.selectedDay)
            reloadRecentEntries()
            reloadFavorites()
        }
        .onChange(of: settings.selectedDay) { _, newDay in
            vm.ensureLoaded(for: newDay)
        }
        .onChange(of: vm.composerText) { _, _ in
            vm.persistDraft()
        }
        .onReceive(NotificationCenter.default.publisher(for: .foodEntryRegistered)) { notification in
            let text = (notification.userInfo?["text"] as? String) ?? "Запись зарегистрирована"
            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                toastText = text
            }
            reloadRecentEntries()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
                withAnimation(.easeOut(duration: 0.2)) {
                    toastText = nil
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .foodLogDidChange)) { _ in
            reloadRecentEntries()
            reloadFavorites()
        }
        .onReceive(NotificationCenter.default.publisher(for: .favoritesDidChange)) { _ in
            reloadFavorites()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
            withAnimation(.easeOut(duration: duration)) {
                isKeyboardVisible = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { notification in
            let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
            withAnimation(.easeOut(duration: duration)) {
                isKeyboardVisible = false
            }
        }
        .sheet(isPresented: $showPicker) {
            MultiImagePicker(maxSelection: 8) { imgs in
                vm.addImages(imgs)
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraImagePicker { img in
                if let img {
                    vm.addImages([img])
                }
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(item: Binding<EditingDraftImageItem?>(
            get: {
                guard let idx = editingDraftImageIndex,
                      vm.composerImages.indices.contains(idx) else { return nil }
                return EditingDraftImageItem(index: idx)
            },
            set: { newValue in
                editingDraftImageIndex = newValue?.index
            }
        )) { item in
            if let image = editingDraftImage {
                QuickImageEditorScreen(
                    image: image,
                    title: "Редактор фото",
                    onCancel: {
                        editingDraftImageIndex = nil
                    },
                    onDone: { edited in
                        replaceComposerImage(at: item.index, with: edited)
                        editingDraftImageIndex = nil
                    }
                )
            }
        }
        .alert("Ошибка", isPresented: .constant(vm.lastError != nil), actions: {
            Button("OK") { vm.lastError = nil }
        }, message: {
            Text(vm.lastError ?? "")
        })
        .sheet(isPresented: Binding(
            get: { addDayCandidate != nil },
            set: { if !$0 { addDayCandidate = nil } }
        )) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Выбери день для добавления блюда")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.appTextPrimary)
                    .padding(.bottom, 6)

                ForEach(editableDays, id: \.self) { day in
                    Button {
                        if let entry = addDayCandidate {
                            addRecentEntry(entry, to: day)
                        }
                        addDayCandidate = nil
                    } label: {
                        Text(editableDayTitle(day))
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .foregroundStyle(Color.appTextPrimary)
                            .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                Button("Отмена") {
                    addDayCandidate = nil
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.appTextSecondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
            }
            .padding(16)
            .presentationDetents([.height(280)])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.appBackground)
        }
        .alert("Убрать из избранного?", isPresented: Binding(
            get: { removeFavoriteCandidate != nil },
            set: { if !$0 { removeFavoriteCandidate = nil } }
        )) {
            Button("Убрать", role: .destructive) {
                if let candidate = removeFavoriteCandidate {
                    favoritesStore.remove(candidate)
                    reloadFavorites()
                    NotificationCenter.default.post(name: .favoritesDidChange, object: nil)
                }
                removeFavoriteCandidate = nil
            }
            Button("Отмена", role: .cancel) {
                removeFavoriteCandidate = nil
            }
        }
        .sheet(item: $editFavoriteCandidate) { favorite in
            FavoriteFoodEditView(
                favorite: favorite,
                originalFavorite: favorite,
                onSave: { original, updated in
                    favoritesStore.update(updated)
                    applyFavoriteUpdateToLogs(from: original, to: updated)
                    reloadFavorites()
                    reloadRecentEntries()
                    NotificationCenter.default.post(name: .favoritesDidChange, object: nil)
                    NotificationCenter.default.post(name: .foodLogDidChange, object: nil)
                },
                onDelete: { removing in
                    favoritesStore.remove(removing)
                    reloadFavorites()
                    NotificationCenter.default.post(name: .favoritesDidChange, object: nil)
                }
            )
        }
        .fullScreenCover(item: $previewItem) { item in
            ImagePreviewScreen(image: item.image) {
                previewItem = nil
            }
        }
        .overlay(alignment: .top) {
            if let toastText {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                    Text(toastText)
                }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.appTextPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.appSurfaceElevated, in: Capsule())
                    .overlay {
                        Capsule().stroke(Color.black.opacity(0.08), lineWidth: 0.8)
                    }
                    .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 2)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private func replaceComposerImage(at index: Int, with image: UIImage) {
        guard vm.composerImages.indices.contains(index) else { return }
        vm.composerImages[index] = image
        vm.persistDraft()
    }

    private var editableDays: [Date] {
        var cal = Calendar.current
        cal.firstWeekday = 2
        let today = cal.startOfDay(for: Date())
        return (0..<3).compactMap { cal.date(byAdding: .day, value: -$0, to: today) }
    }

    private func editableDayTitle(_ day: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM"
        let base = f.string(from: day).capitalized

        let cal = Calendar.current
        if cal.isDateInToday(day) {
            return "\(base) (сегодня)"
        }
        return base
    }

    private func presentAddDaySheet(for entry: FoodEntry) {
        let shouldDelayPresentation = isKeyboardVisible
        dismissKeyboard()

        let present = {
            addDayCandidate = entry
        }

        if shouldDelayPresentation {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                present()
            }
        } else {
            present()
        }
    }

    private func addRecentEntry(_ entry: FoodEntry, to day: Date) {
        let key = foodStore.dayKey(for: day)
        var entries = foodStore.load(dayKey: key)
        entries.append(
            FoodEntry(
                name: entry.name,
                calories: entry.calories,
                protein: entry.protein,
                fat: entry.fat,
                carbs: entry.carbs
            )
        )
        foodStore.save(entries, dayKey: key)
        NotificationCenter.default.post(name: .foodLogDidChange, object: nil)

        let dayText = editableDayTitle(day)
        withAnimation(.easeInOut(duration: 0.2)) {
            toastText = "Добавлено в \(dayText)"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation(.easeOut(duration: 0.2)) {
                toastText = nil
            }
        }
    }

    private func addToFavorites(_ entry: FoodEntry) {
        switch favoritesStore.add(entry) {
        case .added:
            reloadFavorites()
            NotificationCenter.default.post(name: .favoritesDidChange, object: nil)
            withAnimation(.easeInOut(duration: 0.2)) {
                toastText = "Добавлено в избранное"
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation(.easeOut(duration: 0.2)) {
                    toastText = nil
                }
            }
        case .alreadyExists:
            withAnimation(.easeInOut(duration: 0.2)) {
                toastText = "Это блюдо уже в избранном"
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation(.easeOut(duration: 0.2)) {
                    toastText = nil
                }
            }
        }
    }

    private func reloadFavorites() {
        var cal = Calendar.current
        cal.firstWeekday = 2
        let today = cal.startOfDay(for: Date())
        let minDate = cal.date(byAdding: .month, value: -FoodLogStore.retentionMonths, to: today) ?? today

        var lastUsageBySignature: [String: Date] = [:]
        var day: Date? = today
        while let currentDay = day, currentDay >= minDate {
            defer { day = cal.date(byAdding: .day, value: -1, to: currentDay) }
            let key = foodStore.dayKey(for: currentDay)
            for entry in foodStore.load(dayKey: key, syncCloud: false) {
                let sig = recentSignature(for: entry)
                if let old = lastUsageBySignature[sig] {
                    if entry.createdAt > old { lastUsageBySignature[sig] = entry.createdAt }
                } else {
                    lastUsageBySignature[sig] = entry.createdAt
                }
            }
        }

        favoriteEntries = favoritesStore.load().sorted { lhs, rhs in
            let lUsed = lastUsageBySignature[favoriteSignature(for: lhs)]
            let rUsed = lastUsageBySignature[favoriteSignature(for: rhs)]

            switch (lUsed, rUsed) {
            case let (l?, r?):
                if l != r { return l > r }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    private func applyFavoriteUpdateToLogs(from old: FavoriteFood, to updated: FavoriteFood) {
        var cal = Calendar.current
        cal.firstWeekday = 2
        let today = cal.startOfDay(for: Date())
        let minDate = cal.date(byAdding: .month, value: -FoodLogStore.retentionMonths, to: today) ?? today
        let oldSig = favoriteSignature(for: old)

        var day: Date? = today
        while let currentDay = day, currentDay >= minDate {
            defer { day = cal.date(byAdding: .day, value: -1, to: currentDay) }
            let key = foodStore.dayKey(for: currentDay)
            var entries = foodStore.load(dayKey: key, syncCloud: false)
            var changed = false

            for idx in entries.indices {
                if recentSignature(for: entries[idx]) == oldSig {
                    let existing = entries[idx]
                    entries[idx] = FoodEntry(
                        id: existing.id,
                        name: updated.name,
                        calories: updated.calories,
                        protein: updated.protein,
                        fat: updated.fat,
                        carbs: updated.carbs,
                        createdAt: existing.createdAt
                    )
                    changed = true
                }
            }

            if changed {
                foodStore.save(entries, dayKey: key)
            }
        }
    }

    private func favoriteSignature(for favorite: FavoriteFood) -> String {
        let normalizedName = favorite.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let kcal = Int(favorite.calories.rounded())
        let p = Int(favorite.protein.rounded())
        let f = Int(favorite.fat.rounded())
        let c = Int(favorite.carbs.rounded())
        return "\(normalizedName)|\(kcal)|\(p)|\(f)|\(c)"
    }

    private func reloadRecentEntries() {
        var cal = Calendar.current
        cal.firstWeekday = 2
        let today = cal.startOfDay(for: Date())
        let minDate = cal.date(byAdding: .month, value: -FoodLogStore.retentionMonths, to: today) ?? today
        var all: [FoodEntry] = []

        var day: Date? = today
        while let currentDay = day, currentDay >= minDate {
            defer { day = cal.date(byAdding: .day, value: -1, to: currentDay) }
            let key = foodStore.dayKey(for: currentDay)
            all.append(contentsOf: foodStore.load(dayKey: key, syncCloud: false))
        }

        let sorted = all.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        var seen: Set<String> = []
        var unique: [FoodEntry] = []

        for entry in sorted {
            let signature = recentSignature(for: entry)
            if seen.contains(signature) { continue }
            seen.insert(signature)
            unique.append(entry)
        }

        recentEntries = unique
    }

    private func recentSignature(for entry: FoodEntry) -> String {
        let normalizedName = entry.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let kcal = Int(entry.calories.rounded())
        let p = Int(entry.protein.rounded())
        let f = Int(entry.fat.rounded())
        let c = Int(entry.carbs.rounded())
        return "\(normalizedName)|\(kcal)|\(p)|\(f)|\(c)"
    }

    @ViewBuilder
    private var contentArea: some View {
        switch selectedTab {
        case .chat:
            chat
        case .favorites:
            favoritesList
        case .recent:
            recentList
        }
    }

    private var modeTabs: some View {
        HStack(spacing: 10) {
            ForEach([ContentTab.chat, .favorites, .recent], id: \.rawValue) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        setSelectedTab(tab)
                    }
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(selectedTab == tab ? Color.appTextPrimary : Color.appTextSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(selectedTab == tab ? Color.appSurfaceElevated : Color.appSurface.opacity(0.65), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var filteredFavoriteEntries: [FavoriteFood] {
        let q = favoritesSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return favoriteEntries }
        return favoriteEntries.filter { $0.name.lowercased().contains(q) }
    }

    private var favoritesList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if filteredFavoriteEntries.isEmpty {
                    Text(favoriteEntries.isEmpty ? "Избранное пока пусто" : "Ничего не найдено")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Color.appTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                } else {
                    ForEach(filteredFavoriteEntries) { favorite in
                        Button {
                            // intentionally no-op; tap gives visual feedback only
                        } label: {
                            recentEntryCard(
                                FoodEntry(
                                    id: favorite.id,
                                    name: favorite.name,
                                    calories: favorite.calories,
                                    protein: favorite.protein,
                                    fat: favorite.fat,
                                    carbs: favorite.carbs,
                                    createdAt: favorite.createdAt
                                ),
                                showsDate: false
                            )
                        }
                        .buttonStyle(CardPressFeedbackStyle())
                        .contextMenu {
                            Button {
                                presentAddDaySheet(
                                    for: FoodEntry(
                                        name: favorite.name,
                                        calories: favorite.calories,
                                        protein: favorite.protein,
                                        fat: favorite.fat,
                                        carbs: favorite.carbs
                                    )
                                )
                            } label: {
                                Label("Добавить", systemImage: "plus.circle")
                            }

                            Button {
                                editFavoriteCandidate = favorite
                            } label: {
                                Label("Редактировать", systemImage: "pencil")
                            }

                            Button(role: .destructive) {
                                removeFavoriteCandidate = favorite
                            } label: {
                                Label("Убрать из избранного", systemImage: "star.slash")
                            }
                        }
                    }
                }
            }
            .padding(.top, 12)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
    }

    private var filteredRecentEntries: [FoodEntry] {
        let q = recentSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return recentEntries }
        return recentEntries.filter { $0.name.lowercased().contains(q) }
    }

    private var recentList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if filteredRecentEntries.isEmpty {
                    Text(recentEntries.isEmpty ? "За последние 6 месяцев записей пока нет" : "Ничего не найдено")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Color.appTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                } else {
                    ForEach(filteredRecentEntries) { entry in
                        Button {
                            // intentionally no-op; tap gives visual feedback only
                        } label: {
                            recentEntryCard(entry)
                        }
                        .buttonStyle(CardPressFeedbackStyle())
                        .contextMenu {
                            Button {
                                presentAddDaySheet(for: entry)
                            } label: {
                                Label("Добавить", systemImage: "plus.circle")
                            }

                            Button {
                                addToFavorites(entry)
                            } label: {
                                Label("В избранное", systemImage: "star")
                            }
                        }
                    }
                }
            }
            .padding(.top, 12)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
    }

    private func contentSearchBar() -> some View {
        let textBinding = Binding<String>(
            get: { selectedTab == .favorites ? favoritesSearchText : recentSearchText },
            set: { selectedTab == .favorites ? setFavoritesSearchText($0) : setRecentSearchText($0) }
        )

        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.appTextSecondary)

            TextField("Поиск блюд", text: textBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Color.appTextPrimary)

            if !textBinding.wrappedValue.isEmpty {
                Button {
                    textBinding.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.appTextTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.appTextPrimary)
                    .frame(width: 40, height: 40)
                    .background(Color.appSurface, in: Circle())
            }

            if selectedTab == .recent || selectedTab == .favorites {
                contentSearchBar()
                    .frame(maxWidth: .infinity)
            } else {
                Spacer()

                Text("Добавить еду")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.appTextPrimary)

                Spacer()

                Button { } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.appTextSecondary)
                        .frame(width: 40, height: 40)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var chat: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(vm.messages) { msg in
                        ChatRow(message: msg, onImageTap: { img in
                            previewItem = PreviewImageItem(image: img)
                        })
                            .id(msg.id)
                    }
                }
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(
                TapGesture().onEnded {
                    dismissKeyboard()
                }
            )
            .onAppear {
                guard let last = vm.messages.last else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onChange(of: vm.messages) { _, _ in
                guard let last = vm.messages.last else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func recentEntryCard(_ e: FoodEntry, showsDate: Bool = true) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        return VStack(alignment: .leading, spacing: 7) {
            Text(e.name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.appTextPrimary)

            HStack(alignment: .center, spacing: 8) {
                miniChip("Ккал", Int(e.calories.rounded()))
                miniChip("Б", Int(e.protein.rounded()))
                miniChip("Ж", Int(e.fat.rounded()))
                miniChip("У", Int(e.carbs.rounded()))

                if showsDate {
                    Spacer(minLength: 6)

                    Text(recentDateText(e.createdAt))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.appTextTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.appSurfaceElevated, in: shape)
        .overlay { shape.stroke(Color.black.opacity(0.08), lineWidth: 0.8) }
    }

    private func miniChip(_ title: String, _ value: Int) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.appTextSecondary)
            Text("\(value)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.appTextPrimary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.appBackground, in: Capsule())
    }

    private func recentDateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM, HH:mm"
        return f.string(from: date)
    }

    private var composer: some View {
        VStack(spacing: 10) {
            if !vm.composerImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(vm.composerImages.enumerated()), id: \.offset) { idx, img in
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 64, height: 64)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .onTapGesture {
                                        editingDraftImageIndex = idx
                                    }

                                Button {
                                    vm.removeComposerImage(at: idx)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 22, height: 22)
                                        .background(.black.opacity(0.7), in: Circle())
                                }
                                .padding(6)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            HStack(spacing: 10) {
                Menu {
                    // В Menu на iOS элементы в popup могут визуально идти снизу вверх,
                    // поэтому объявляем в обратном порядке для нужного отображения.
                    Button("Выбрать из галереи") {
                        showPicker = true
                    }
                    Button("Сделать фото") {
                        showCamera = true
                    }
                } label: {
                    Image(systemName: "photo")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.appTextSecondary)
                        .frame(width: 42, height: 42)
                        .background(Color.appSurface, in: Circle())
                }

                TextField("Напишите, что вы ели…", text: $vm.composerText, axis: .vertical)
                    .focused($isComposerFocused)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Color.appTextPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                RecordingToggleButton(recorder: vm.audioRecorder, isTranscribing: vm.isTranscribing) {
                    Task { await vm.toggleRecording() }
                }

                Button {
                    vm.sendInBackground(selectedDay: settings.selectedDay)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .frame(width: 42, height: 42)
                        .background((vm.isSending || vm.isTranscribing || vm.audioRecorder.isRecording) ? Color.appTextTertiary : Color.appTextPrimary, in: Circle())
                }
                .disabled(vm.isSending || vm.isTranscribing || vm.audioRecorder.isRecording)
            }
            .padding(.horizontal, 16)

            Rectangle()
                .fill(Color.clear)
                .frame(height: 8)
        }
        .padding(.top, 10)
        .background(Color.appBackground)
    }
}

private struct RecordingToggleButton: View {
    @ObservedObject var recorder: AudioRecorder
    let isTranscribing: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                if isTranscribing {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(Color.appTextSecondary)
                } else if recorder.isRecording {
                    RecordingWaveformIcon(level: recorder.inputLevel)
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Color.appTextSecondary)
                }
            }
            .frame(width: 46, height: 46)
            .background(recorder.isRecording ? .red.opacity(0.9) : Color.appSurface, in: Circle())
        }
        .disabled(isTranscribing)
    }
}

private struct RecordingWaveformIcon: View {
    let level: Double // 0...1
    private let barGains: [CGFloat] = [0.55, 0.8, 1.0, 0.8, 0.55]

    var body: some View {
        let clamped = min(max(level, 0), 1)
        let boosted = min(1.0, clamped * 1.8)
        TimelineView(.animation(minimumInterval: 1.0 / 40.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<5, id: \.self) { i in
                    let h = barHeight(index: i, time: t, level: boosted)
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .frame(width: 2.5, height: h)
                }
            }
            .frame(width: 20, height: 20)
        }
    }

    private func barHeight(index: Int, time: TimeInterval, level: Double) -> CGFloat {
        let base: CGFloat = 3
        let maxExtra: CGFloat = 14
        let phase = Double(index) * 0.75
        let motion = (sin(time * 10 + phase) + 1) * 0.5 // 0...1
        let liveLevel = level * (0.7 + 0.3 * motion)
        return base + CGFloat(liveLevel) * maxExtra * barGains[index]
    }
}

private struct ChatRow: View {
    let message: ChatMessage
    let onImageTap: (UIImage) -> Void

    private var isUser: Bool { message.role == .user }
    private let sideInset: CGFloat = 16
    private var rowWidth: CGFloat {
        max(UIScreen.main.bounds.width - sideInset * 2, 0)
    }
    private var bubbleMaxWidth: CGFloat { rowWidth * 0.78 }

    var body: some View {
        HStack(spacing: 0) {
            if isUser {
                Spacer(minLength: 0)
                ChatBubble(message: message, onImageTap: onImageTap)
                    .frame(maxWidth: bubbleMaxWidth, alignment: .trailing)
            } else {
                ChatBubble(message: message, onImageTap: onImageTap)
                    .frame(maxWidth: bubbleMaxWidth, alignment: .leading)
                Spacer(minLength: 0)
            }
        }
        .frame(width: rowWidth, alignment: isUser ? .trailing : .leading)
        .padding(.horizontal, sideInset)
    }
}

private struct ChatBubble: View {
    let message: ChatMessage
    let onImageTap: (UIImage) -> Void

    var isUser: Bool { message.role == .user }
    private var isRegistrationStatus: Bool {
        guard message.role == .assistant else { return false }
        let t = message.text.lowercased()
        return t.contains("зарегистрировано") || t.contains("зарегистрирована") || t.contains("зарегистрированы")
    }
    private var messageTextColor: Color {
        isUser ? Color(uiColor: .systemBackground) : Color.appTextPrimary
    }
    private var markdownText: AttributedString? {
        // Для коротких статусных сообщений отключаем markdown,
        // чтобы избежать странного рендера/межстрочных отступов.
        guard !isRegistrationStatus else { return nil }

        // В обычном markdown одиночные \n часто схлопываются в один абзац.
        // Этот режим сохраняет переносы строки как есть.
        var options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        options.failurePolicy = .returnPartiallyParsedIfPossible
        return try? AttributedString(markdown: message.text, options: options)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !message.images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(message.images.enumerated()), id: \.offset) { _, img in
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 160, height: 200)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .onTapGesture {
                                    onImageTap(img)
                                }
                        }
                    }
                }
            }

            if message.isPending && message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                TypingDotsView(isUser: isUser)
            } else if !message.text.isEmpty {
                Group {
                    if isRegistrationStatus {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14, weight: .bold))
                            Text(message.text)
                        }
                    } else if let markdownText {
                        Text(markdownText)
                    } else {
                        Text(message.text)
                    }
                }
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(messageTextColor)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, isRegistrationStatus ? 8 : 12)
        .background(isUser ? Color.appBubbleUser : Color.appBubbleAssistant, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contextMenu {
            if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    UIPasteboard.general.string = message.text
                } label: {
                    Label("Скопировать", systemImage: "doc.on.doc")
                }
            }
        }
    }
}

private struct QuickImageEditorScreen: View {
    let image: UIImage
    let title: String
    let onCancel: () -> Void
    let onDone: (UIImage) -> Void

    @State private var workingImage: UIImage
    @State private var cropRect: CGRect = .zero

    init(
        image: UIImage,
        title: String,
        onCancel: @escaping () -> Void,
        onDone: @escaping (UIImage) -> Void
    ) {
        self.image = image
        self.title = title
        self.onCancel = onCancel
        self.onDone = onDone
        _workingImage = State(initialValue: image.normalizedUp())
    }

    var body: some View {
        GeometryReader { geo in
            let canvas = geo.size
            let imageFrame = aspectFitFrame(imageSize: workingImage.size, in: canvas)

            ZStack {
                Color.black.ignoresSafeArea()

                Image(uiImage: workingImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: imageFrame.width, height: imageFrame.height)
                    .position(x: imageFrame.midX, y: imageFrame.midY)

                ResizableCropOverlay(
                    cropRect: $cropRect,
                    boundsRect: imageFrame
                )
            }
            .onAppear {
                if cropRect == .zero { cropRect = imageFrame }
            }
            .onChange(of: workingImage) { _, _ in
                cropRect = imageFrame
            }
            .overlay(alignment: .top) {
                HStack {
                    Button("Отмена") { onCancel() }
                    Spacer()
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button("Готово") {
                        onDone(workingImage.cropped(displayedImageFrame: imageFrame, cropRect: cropRect))
                    }
                    .fontWeight(.semibold)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }
            .overlay(alignment: .bottom) {
                HStack(spacing: 18) {
                    Button {
                        workingImage = workingImage.rotated90(clockwise: false)
                    } label: {
                        Label("Влево", systemImage: "rotate.left")
                    }

                    Button {
                        workingImage = workingImage.rotated90(clockwise: true)
                    } label: {
                        Label("Вправо", systemImage: "rotate.right")
                    }

                    Button {
                        cropRect = imageFrame
                    } label: {
                        Label("Сброс", systemImage: "arrow.counterclockwise")
                    }
                }
                .labelStyle(.titleAndIcon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.45), in: Capsule())
                .padding(.bottom, 22)
            }
        }
    }

    private func aspectFitFrame(imageSize: CGSize, in canvas: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, canvas.width > 0, canvas.height > 0 else { return .zero }
        let scale = min(canvas.width / imageSize.width, canvas.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: (canvas.width - w) / 2, y: (canvas.height - h) / 2, width: w, height: h)
    }
}

private struct ResizableCropOverlay: View {
    @Binding var cropRect: CGRect
    let boundsRect: CGRect

    private let handle: CGFloat = 24
    private let minSize: CGFloat = 80

    var body: some View {
        ZStack {
            Path { path in
                path.addRect(boundsRect)
                path.addRect(cropRect)
            }
            .fill(Color.black.opacity(0.42), style: FillStyle(eoFill: true))

            Rectangle()
                .stroke(Color.white.opacity(0.95), lineWidth: 2)
                .frame(width: cropRect.width, height: cropRect.height)
                .position(x: cropRect.midX, y: cropRect.midY)

            handleView(at: CGPoint(x: cropRect.minX, y: cropRect.minY), mode: .topLeft)
            handleView(at: CGPoint(x: cropRect.maxX, y: cropRect.minY), mode: .topRight)
            handleView(at: CGPoint(x: cropRect.minX, y: cropRect.maxY), mode: .bottomLeft)
            handleView(at: CGPoint(x: cropRect.maxX, y: cropRect.maxY), mode: .bottomRight)
        }
        .allowsHitTesting(boundsRect != .zero)
    }

    private enum HandleMode { case topLeft, topRight, bottomLeft, bottomRight }

    private func handleView(at point: CGPoint, mode: HandleMode) -> some View {
        Circle()
            .fill(.white)
            .frame(width: handle, height: handle)
            .position(x: point.x, y: point.y)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        updateRect(with: value.location, mode: mode)
                    }
            )
    }

    private func updateRect(with p: CGPoint, mode: HandleMode) {
        let clampedX = min(max(p.x, boundsRect.minX), boundsRect.maxX)
        let clampedY = min(max(p.y, boundsRect.minY), boundsRect.maxY)

        let left = cropRect.minX
        let right = cropRect.maxX
        let top = cropRect.minY
        let bottom = cropRect.maxY

        var newLeft = left
        var newRight = right
        var newTop = top
        var newBottom = bottom

        switch mode {
        case .topLeft:
            newLeft = min(clampedX, right - minSize)
            newTop = min(clampedY, bottom - minSize)
        case .topRight:
            newRight = max(clampedX, left + minSize)
            newTop = min(clampedY, bottom - minSize)
        case .bottomLeft:
            newLeft = min(clampedX, right - minSize)
            newBottom = max(clampedY, top + minSize)
        case .bottomRight:
            newRight = max(clampedX, left + minSize)
            newBottom = max(clampedY, top + minSize)
        }

        newLeft = max(newLeft, boundsRect.minX)
        newTop = max(newTop, boundsRect.minY)
        newRight = min(newRight, boundsRect.maxX)
        newBottom = min(newBottom, boundsRect.maxY)

        if newRight - newLeft < minSize { newRight = min(boundsRect.maxX, newLeft + minSize) }
        if newBottom - newTop < minSize { newBottom = min(boundsRect.maxY, newTop + minSize) }

        cropRect = CGRect(x: newLeft, y: newTop, width: newRight - newLeft, height: newBottom - newTop)
    }
}

private extension UIImage {
    func normalizedUp() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    func rotated90(clockwise: Bool) -> UIImage {
        let base = normalizedUp()
        let newSize = CGSize(width: base.size.height, height: base.size.width)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = base.scale
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)

        return renderer.image { ctx in
            let cg = ctx.cgContext
            cg.translateBy(x: newSize.width / 2, y: newSize.height / 2)
            cg.rotate(by: clockwise ? .pi / 2 : -.pi / 2)
            base.draw(in: CGRect(x: -base.size.width / 2, y: -base.size.height / 2, width: base.size.width, height: base.size.height))
        }
    }

    func cropped(displayedImageFrame: CGRect, cropRect: CGRect) -> UIImage {
        let base = normalizedUp()
        guard let cg = base.cgImage else { return base }

        let xRatio = CGFloat(cg.width) / max(displayedImageFrame.width, 1)
        let yRatio = CGFloat(cg.height) / max(displayedImageFrame.height, 1)

        var cropPx = CGRect(
            x: (cropRect.minX - displayedImageFrame.minX) * xRatio,
            y: (cropRect.minY - displayedImageFrame.minY) * yRatio,
            width: cropRect.width * xRatio,
            height: cropRect.height * yRatio
        )

        let bounds = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        cropPx = cropPx.integral.intersection(bounds)

        guard cropPx.width > 1, cropPx.height > 1,
              let cropped = cg.cropping(to: cropPx) else {
            return base
        }

        return UIImage(cgImage: cropped, scale: base.scale, orientation: .up)
    }
}

private struct CardPressFeedbackStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

private struct FavoriteFoodEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State var favorite: FavoriteFood
    @State private var showDeleteConfirm = false
    let originalFavorite: FavoriteFood
    let onSave: (FavoriteFood, FavoriteFood) -> Void
    let onDelete: (FavoriteFood) -> Void

    private var calculatedCalories: Double {
        favorite.protein * 4 + favorite.fat * 9 + favorite.carbs * 4
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Блюдо") {
                    TextField("Название", text: $favorite.name)
                }

                Section("Пищевая ценность") {
                    HStack {
                        Text("Калории")
                        Spacer()
                        Text("\(Int(calculatedCalories.rounded())) ккал")
                            .foregroundStyle(.secondary)
                    }

                    labeledNumberField("Белки", value: $favorite.protein, suffix: "г")
                    labeledNumberField("Жиры", value: $favorite.fat, suffix: "г")
                    labeledNumberField("Углеводы", value: $favorite.carbs, suffix: "г")
                }

                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Text("Убрать из избранного")
                    }
                }
            }
            .navigationTitle("Редактировать")
            .alert("Убрать из избранного?", isPresented: $showDeleteConfirm) {
                Button("Убрать", role: .destructive) {
                    onDelete(favorite)
                    dismiss()
                }
                Button("Отмена", role: .cancel) {}
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        favorite.calories = calculatedCalories
                        onSave(originalFavorite, favorite)
                        dismiss()
                    }
                    .disabled(favorite.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private func labeledNumberField(_ title: String, value: Binding<Double>, suffix: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0", value: value, format: .number)
                .multilineTextAlignment(.trailing)
                .keyboardType(.decimalPad)
            Text(suffix)
                .foregroundStyle(.secondary)
        }
    }
}

private struct EditingDraftImageItem: Identifiable {
    let index: Int
    var id: Int { index }
}

private struct PreviewImageItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct ImagePreviewScreen: View {
    let image: UIImage
    let onClose: () -> Void

    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1
    @State private var savedMessage: String?
    @State private var dragOffsetY: CGFloat = 0
    @State private var showSaveConfirm = false

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
                .opacity(max(0.45, 1 - abs(dragOffsetY) / 260.0))

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 12)
                .scaleEffect(zoom)
                .offset(y: dragOffsetY)
                .gesture(magnificationGesture)
                .simultaneousGesture(dismissDragGesture)

            VStack {
                HStack {
                    Button {
                        showSaveConfirm = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.black.opacity(0.55), in: Circle())
                    }

                    Spacer()

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                }
                .padding(.top, 14)
                .padding(.horizontal, 14)

                Spacer()

                if let savedMessage {
                    Text(savedMessage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.65), in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.opacity)
                }
            }
        }
        .statusBarHidden(true)
        .alert("Сохранить фото?", isPresented: $showSaveConfirm) {
            Button("Сохранить") {
                Task { await saveToPhotos() }
            }
            Button("Отмена", role: .cancel) { }
        } message: {
            Text("Сохранить изображение в Фото?")
        }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let next = lastZoom * value
                zoom = min(max(next, 1), 5)
            }
            .onEnded { value in
                let next = lastZoom * value
                zoom = min(max(next, 1), 5)
                lastZoom = zoom
            }
    }

    private var dismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard zoom <= 1.02 else { return }
                dragOffsetY = value.translation.height
            }
            .onEnded { value in
                guard zoom <= 1.02 else { return }
                if abs(value.translation.height) > 120 {
                    onClose()
                } else {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        dragOffsetY = 0
                    }
                }
            }
    }

    private func saveToPhotos() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            await MainActor.run {
                withAnimation { savedMessage = "Нет доступа к Фото" }
                hideToastLater()
            }
            return
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.creationRequestForAsset(from: image)
            }
            await MainActor.run {
                withAnimation { savedMessage = "Сохранено в Фото" }
                hideToastLater()
            }
        } catch {
            await MainActor.run {
                withAnimation { savedMessage = "Ошибка сохранения" }
                hideToastLater()
            }
        }
    }

    private func hideToastLater() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { savedMessage = nil }
        }
    }
}

private struct TypingDotsView: View {
    let isUser: Bool
    @State private var phase: Int = 0
    private let timer = Timer.publish(every: 0.28, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(dotColor(index: i))
                    .frame(width: 12, height: 12)
                    .scaleEffect(phase == i ? 1.25 : 0.9)
                    .animation(.easeInOut(duration: 0.2), value: phase)
            }
        }
        .padding(.vertical, 2)
        .onReceive(timer) { _ in
            phase = (phase + 1) % 3
        }
    }

    private func dotColor(index: Int) -> Color {
        let active = phase == index
        if isUser {
            return active ? Color(uiColor: .systemBackground) : Color(uiColor: .systemBackground).opacity(0.5)
        }
        return active ? Color.appTextPrimary : Color.appTextSecondary.opacity(0.55)
    }
}

#Preview {
    FoodChatView()
}
