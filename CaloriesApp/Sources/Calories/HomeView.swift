import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var foodEntries: [FoodEntry] = []
    @State private var editingEntry: FoodEntry?
    @State private var showEntriesSheet = false
    @State private var deleteCandidate: FoodEntry?
    @State private var repeatCandidate: FoodEntry?
    @State private var favoritesMessage: String?
    @State private var weekOffset = 0 // 0 = текущая неделя, 1...N = прошлые

    private let foodStore = FoodLogStore()
    private let favoritesStore = FavoritesStore()

    private var calendar: Calendar {
        var cal = Calendar.current
        cal.firstWeekday = 2
        return cal
    }

    private var selectedDay: Date {
        calendar.startOfDay(for: settings.selectedDay)
    }

    private var today: Date {
        calendar.startOfDay(for: Date())
    }

    private var currentWeekStart: Date {
        weekStart(for: today)
    }

    private var displayedWeekStart: Date {
        calendar.date(byAdding: .day, value: -weekOffset * 7, to: currentWeekStart) ?? currentWeekStart
    }

    private var weekDays: [Date] {
        weekDays(from: displayedWeekStart)
    }

    private func weekDays(from start: Date) -> [Date] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private var oldestAllowedDay: Date {
        calendar.date(byAdding: .month, value: -FoodLogStore.retentionMonths, to: today) ?? today
    }

    private var oldestAllowedWeekStart: Date {
        weekStart(for: oldestAllowedDay)
    }

    private var weekPageCount: Int {
        let days = calendar.dateComponents([.day], from: oldestAllowedWeekStart, to: currentWeekStart).day ?? 0
        return max(1, days / 7 + 1)
    }

    private var maxWeekOffset: Int {
        weekPageCount - 1
    }

    private var chatEditableFromDay: Date {
        calendar.date(byAdding: .day, value: -2, to: today) ?? today
    }

    private var canChatForSelectedDay: Bool {
        selectedDay >= chatEditableFromDay && selectedDay <= today
    }

    private func weekStart(for date: Date) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: startOfDay)
        return calendar.date(byAdding: .day, value: -(weekday - calendar.firstWeekday + 7) % 7, to: startOfDay) ?? startOfDay
    }

    private var consumedCalories: Int { Int(foodEntries.reduce(0) { $0 + $1.calories }.rounded()) }
    private var consumedProtein: Int { Int(foodEntries.reduce(0) { $0 + $1.protein }.rounded()) }
    private var consumedFat: Int { Int(foodEntries.reduce(0) { $0 + $1.fat }.rounded()) }
    private var consumedCarbs: Int { Int(foodEntries.reduce(0) { $0 + $1.carbs }.rounded()) }

    private var caloriesProgress: Double {
        guard settings.targetCalories > 0 else { return 0 }
        return min(max(Double(consumedCalories) / Double(settings.targetCalories), 0), 1)
    }

    private var avg7d: (calories: Int, protein: Int, fat: Int, carbs: Int) {
        var kcal: Double = 0
        var p: Double = 0
        var f: Double = 0
        var c: Double = 0
        var daysCount = 0

        // Считаем среднее относительно выбранного дня: берём 7 дней ДО selectedDay,
        // не включая сам selectedDay и пропуская дни с 0 ккал.
        for i in 1...7 {
            guard let day = calendar.date(byAdding: .day, value: -i, to: selectedDay) else { continue }
            let entries = foodStore.load(dayKey: foodStore.dayKey(for: day), syncCloud: false)
            let dayCalories = entries.reduce(0) { $0 + $1.calories }
            if dayCalories <= 0 { continue }

            kcal += dayCalories
            p += entries.reduce(0) { $0 + $1.protein }
            f += entries.reduce(0) { $0 + $1.fat }
            c += entries.reduce(0) { $0 + $1.carbs }
            daysCount += 1
        }

        guard daysCount > 0 else { return (0, 0, 0, 0) }
        return (
            Int((kcal / Double(daysCount)).rounded()),
            Int((p / Double(daysCount)).rounded()),
            Int((f / Double(daysCount)).rounded()),
            Int((c / Double(daysCount)).rounded())
        )
    }

    private func dayCalories(_ day: Date) -> Int {
        let key = foodStore.dayKey(for: day)
        let entries = foodStore.load(dayKey: key, syncCloud: false)
        return Int(entries.reduce(0) { $0 + $1.calories }.rounded())
    }

    private var headerDateText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM"
        let dayMonth = f.string(from: selectedDay).capitalized
        let y = calendar.component(.year, from: selectedDay) % 100
        return "\(dayMonth) '\(String(format: "%02d", y))"
    }

    private var headerWeekdayText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "EEEE"
        return f.string(from: selectedDay).capitalized
    }

    private func noGrouping(_ value: Int) -> String {
        var f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                top
                calendarStrip
                Spacer().frame(height: 18)

                BicepProgressIcon(
                    symbolName: settings.progressIcon.symbolName,
                    progress: caloriesProgress,
                    filled: settings.fillBicepProgress
                )
                .padding(.vertical, 20)

                Text("\(String(consumedCalories)) / \(String(settings.targetCalories))")
                    .font(.system(size: 52, weight: .heavy))
                    .foregroundStyle(Color.appTextPrimary)
                Text("СЪЕДЕННЫЕ КАЛОРИИ")
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Color.appTextSecondary)
                if settings.show7dAverage {
                    Text("7д ср: \(noGrouping(avg7d.calories)) ккал")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.appTextSecondary)
                }

                Spacer().frame(height: 18)

                macros

                Spacer()

                bottomRow
            }
        }
        .onAppear {
            if selectedDay < oldestAllowedDay { settings.selectedDay = oldestAllowedDay }
            if selectedDay > today { settings.selectedDay = today }
            syncWeekOffsetWithSelectedDay()
            reloadFoodEntries()
        }
        .onChange(of: settings.selectedDay) { _, _ in
            reloadFoodEntries()
        }
        .onReceive(NotificationCenter.default.publisher(for: .supabaseSessionDidChange)) { _ in
            settings.selectedDay = today
            reloadFoodEntries()
        }
        .onReceive(NotificationCenter.default.publisher(for: .foodLogDidChange)) { _ in reloadFoodEntries() }
        .sheet(item: $editingEntry) { entry in
            FoodEntryEditView(
                entry: entry,
                onSave: { updated in saveEditedEntry(updated) },
                onDelete: { toDelete in deleteEntry(toDelete) }
            )
        }
        .sheet(isPresented: $showEntriesSheet) {
            entriesSheet
                .presentationDetents([.medium, .large])
        }
    }

    private func syncWeekOffsetWithSelectedDay() {
        let days = calendar.dateComponents([.day], from: selectedDay, to: today).day ?? 0
        let normalized = max(0, min(maxWeekOffset, days / 7))
        weekOffset = normalized
    }

    private func reloadFoodEntries() {
        foodEntries = foodStore.load(dayKey: foodStore.dayKey(for: selectedDay))
    }

    private func saveEditedEntry(_ updated: FoodEntry) {
        let key = foodStore.dayKey(for: selectedDay)
        var entries = foodStore.load(dayKey: key, syncCloud: false)
        if let idx = entries.firstIndex(where: { $0.id == updated.id }) {
            entries[idx] = updated
            foodStore.save(entries, dayKey: key)
            foodEntries = entries
            NotificationCenter.default.post(name: .foodLogDidChange, object: nil)
        }
    }

    private func deleteEntry(_ entry: FoodEntry) {
        let key = foodStore.dayKey(for: selectedDay)
        var entries = foodStore.load(dayKey: key, syncCloud: false)
        entries.removeAll { $0.id == entry.id }
        foodStore.save(entries, dayKey: key)
        foodEntries = entries
        NotificationCenter.default.post(name: .foodLogDidChange, object: nil)
    }

    private func addEntryAgainToSelectedDay(_ entry: FoodEntry) {
        guard canChatForSelectedDay else { return }

        let dayKey = foodStore.dayKey(for: selectedDay)
        var dayEntries = foodStore.load(dayKey: dayKey, syncCloud: false)
        let duplicated = FoodEntry(
            name: entry.name,
            calories: entry.calories,
            protein: entry.protein,
            fat: entry.fat,
            carbs: entry.carbs
        )
        dayEntries.append(duplicated)
        foodStore.save(dayEntries, dayKey: dayKey)

        foodEntries = dayEntries
        NotificationCenter.default.post(name: .foodLogDidChange, object: nil)
    }

    private func addToFavorites(_ entry: FoodEntry) {
        switch favoritesStore.add(entry) {
        case .added:
            favoritesMessage = "Добавлено в избранное"
            NotificationCenter.default.post(name: .favoritesDidChange, object: nil)
        case .alreadyExists:
            favoritesMessage = "Это блюдо уже в избранном"
        }
    }

    private func weekdayShort(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "EE"
        return f.string(from: date).replacingOccurrences(of: ".", with: "").uppercased()
    }

    private var top: some View {
        HStack {
            if !calendar.isDate(selectedDay, inSameDayAs: today) {
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        settings.selectedDay = today
                        weekOffset = 0
                    }
                } label: {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.appTextSecondary)
                        .frame(width: 44, height: 44)
                        .background(Color.appSurface, in: Circle())
                }
                .frame(width: 44, height: 44)
            } else {
                Color.clear.frame(width: 44, height: 44)
            }

            Spacer()
            VStack(spacing: 2) {
                Text(headerDateText)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.appTextPrimary)
                Text(headerWeekdayText)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Color.appTextSecondary)
            }
            .multilineTextAlignment(.center)
            Spacer()
            NavigationLink { SettingsView() } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.appTextSecondary)
                    .frame(width: 44, height: 44)
                    .background(Color.appSurface, in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var calendarStrip: some View {
        let newestPageIndex = maxWeekOffset
        let pageBinding = Binding<Int>(
            get: { newestPageIndex - weekOffset },
            set: { newValue in weekOffset = max(0, min(maxWeekOffset, newestPageIndex - newValue)) }
        )

        return TabView(selection: pageBinding) {
            ForEach(0..<weekPageCount, id: \.self) { pageIndex in
                let offsetFromTodayWeek = newestPageIndex - pageIndex
                let start = calendar.date(byAdding: .day, value: -offsetFromTodayWeek * 7, to: currentWeekStart) ?? currentWeekStart
                weekStrip(start: start)
                    .tag(pageIndex)
                    .padding(.horizontal, 2)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: 88)
        .padding(.top, 16)
        .onChange(of: weekOffset) { _, _ in
            let gen = UIImpactFeedbackGenerator(style: .heavy)
            gen.impactOccurred(intensity: 1.0)
        }
    }

    @ViewBuilder
    private func weekStrip(start: Date) -> some View {
        HStack(spacing: 14) {
            ForEach(weekDays(from: start), id: \.self) { day in
                let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
                let isTodayCell = calendar.isDate(day, inSameDayAs: today)
                let isAllowedToSelect = day >= oldestAllowedDay && day <= today
                let dayText = day <= today ? String(calendar.component(.day, from: day)) : "-"
                let cals = day <= today ? dayCalories(day) : 0

                Button {
                    guard isAllowedToSelect else { return }
                    let gen = UIImpactFeedbackGenerator(style: .light)
                    gen.impactOccurred(intensity: 0.8)
                    settings.selectedDay = day
                } label: {
                    VStack(spacing: 6) {
                        Text(weekdayShort(day))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.appTextTertiary)

                        VStack(spacing: 2) {
                            Text(dayText)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(isSelected ? Color.appTextPrimary : (isTodayCell ? Color.appTextPrimary : Color.appTextSecondary))

                            Text(cals > 0 ? noGrouping(cals) : " ")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.appTextTertiary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .frame(height: 11)
                        }
                        .frame(width: 40, height: 56)
                        .background(isSelected ? Color.appSurface : (isTodayCell ? Color.appSurface.opacity(0.75) : Color.clear), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            if isTodayCell {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color.appTextSecondary.opacity(0.55), lineWidth: 1)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!isAllowedToSelect)
            }
        }
        .padding(.bottom, 4)
    }

    private var macros: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text("БЕЛКИ")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.appTextTertiary)
                Text("\(consumedProtein) / \(Int(settings.targetProtein)) г")
                    .font(.system(size: 18, weight: .semibold))
                if settings.show7dAverage {
                    Text("7д ср: \(noGrouping(avg7d.protein)) г")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.appTextSecondary)
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 5) {
                Text("ЖИРЫ")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.appTextTertiary)
                Text("\(consumedFat) / \(Int(settings.targetFat)) г")
                    .font(.system(size: 18, weight: .semibold))
                if settings.show7dAverage {
                    Text("7д ср: \(noGrouping(avg7d.fat)) г")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.appTextSecondary)
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 5) {
                Text("УГЛЕВОДЫ")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.appTextTertiary)
                Text("\(consumedCarbs) / \(Int(settings.targetCarbs)) г")
                    .font(.system(size: 18, weight: .semibold))
                if settings.show7dAverage {
                    Text("7д ср: \(noGrouping(avg7d.carbs)) г")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.appTextSecondary)
                }
            }
        }
        .foregroundStyle(Color.appTextPrimary)
        .padding(.horizontal, 22)
        .padding(.top, 70)
    }

    private var entriesSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 10) {
                        Image(systemName: "fork.knife")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.appTextPrimary)
                            .frame(width: 32, height: 32)
                            .background(Color.appSurface, in: Circle())

                        Text("Внесено")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(Color.appTextPrimary)
                    }
                    .padding(.top, 10)

                    LazyVStack(spacing: 10) {
                        if foodEntries.isEmpty {
                            Text("Пока ничего не внесено")
                                .foregroundStyle(Color.appTextSecondary)
                                .padding(.top, 8)
                        } else {
                            ForEach(foodEntries) { e in
                                Group {
                                    if canChatForSelectedDay {
                                        Button {
                                            editingEntry = e
                                        } label: {
                                            entryCard(e)
                                        }
                                        .contextMenu {
                                            Button {
                                                repeatCandidate = e
                                            } label: {
                                                Label("Добавить снова", systemImage: "plus.circle")
                                            }

                                            Button {
                                                addToFavorites(e)
                                            } label: {
                                                Label("В избранное", systemImage: "star")
                                            }

                                            Button(role: .destructive) {
                                                deleteCandidate = e
                                            } label: {
                                                Label("Удалить", systemImage: "trash")
                                            }
                                        }
                                    } else {
                                        entryCard(e)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Удалить запись?", isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            )) {
                Button("Удалить", role: .destructive) {
                    if let e = deleteCandidate { deleteEntry(e) }
                    deleteCandidate = nil
                }
                Button("Отмена", role: .cancel) {
                    deleteCandidate = nil
                }
            } message: {
                Text("Это действие нельзя отменить.")
            }
            .alert("Добавить это блюдо снова?", isPresented: Binding(
                get: { repeatCandidate != nil },
                set: { if !$0 { repeatCandidate = nil } }
            )) {
                Button("Добавить") {
                    if let e = repeatCandidate { addEntryAgainToSelectedDay(e) }
                    repeatCandidate = nil
                }
                Button("Отмена", role: .cancel) {
                    repeatCandidate = nil
                }
            } message: {
                Text("Блюдо будет добавлено в выбранный день.")
            }
            .alert("Избранное", isPresented: Binding(
                get: { favoritesMessage != nil },
                set: { if !$0 { favoritesMessage = nil } }
            )) {
                Button("Ок", role: .cancel) {
                    favoritesMessage = nil
                }
            } message: {
                Text(favoritesMessage ?? "")
            }
        }
    }

    private var bottomRow: some View {
        HStack {
            Button {
                let gen = UIImpactFeedbackGenerator(style: .medium)
                gen.impactOccurred(intensity: 0.95)
                showEntriesSheet = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "fork.knife")
                        .font(.system(size: 16, weight: .bold))
                    Text("Внесено: \(foodEntries.count)")
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(Color.appTextPrimary)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(Color.appSurface, in: Capsule())
            }

            Spacer()

            Button {
                let gen = UIImpactFeedbackGenerator(style: .medium)
                gen.impactOccurred(intensity: 0.95)
                NotificationCenter.default.post(name: .presentAddFood, object: nil)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(canChatForSelectedDay ? Color(uiColor: .systemBackground) : Color.appTextSecondary)
                    .frame(width: 64, height: 64)
                    .background((canChatForSelectedDay ? Color.appTextPrimary : Color.appSurface), in: Circle())
                    .opacity(canChatForSelectedDay ? 1.0 : 0.55)
            }
            .disabled(!canChatForSelectedDay)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 18)
    }
}

private struct BicepProgressIcon: View {
    let symbolName: String
    let progress: Double // 0...1
    let filled: Bool

    var body: some View {
        let p = min(max(progress, 0), 1)
        let renderProgress: Double = filled ? p : 1
        let icon = Image(systemName: symbolName)
            .resizable()
            .scaledToFit()
            .frame(width: 120, height: 120)

        ZStack {
            icon
                .foregroundStyle(Color.appTextSecondary.opacity(0.45))

            GeometryReader { geo in
                icon
                    .foregroundStyle(Color.appTextPrimary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .mask(alignment: .bottom) {
                        Rectangle()
                            .frame(height: geo.size.height * renderProgress)
                    }
            }
            .frame(width: 140, height: 140)
        }
        .frame(width: 140, height: 140)
    }
}

private extension HomeView {
    func entryCard(_ e: FoodEntry) -> some View {
        EntryCardView(entry: e)
    }
}

private struct EntryCardView: View {
    let entry: FoodEntry

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM, HH:mm"
        return f
    }()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        VStack(alignment: .leading, spacing: 8) {
            Text(entry.name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.appTextPrimary)

            HStack(spacing: 10) {
                metricChip("Ккал", Int(entry.calories.rounded()))
                metricChip("Б", Int(entry.protein.rounded()))
                metricChip("Ж", Int(entry.fat.rounded()))
                metricChip("У", Int(entry.carbs.rounded()))

                Spacer(minLength: 6)

                Text(Self.dateFormatter.string(from: entry.createdAt))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.appTextTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 112, alignment: .trailing)
                    .layoutPriority(-1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemBackground), in: shape)
        .overlay {
            shape.stroke(Color(uiColor: .separator).opacity(0.55), lineWidth: 0.8)
        }
    }

    private func metricChip(_ title: String, _ value: Int) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.appTextSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: true)
            Text("\(value)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.appTextPrimary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.appBackground, in: Capsule())
        .fixedSize(horizontal: true, vertical: true)
        .layoutPriority(1)
    }
}

private struct FoodEntryEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State var entry: FoodEntry
    @State private var showDeleteConfirm = false
    let onSave: (FoodEntry) -> Void
    let onDelete: (FoodEntry) -> Void

    private var calculatedCalories: Double {
        entry.protein * 4 + entry.fat * 9 + entry.carbs * 4
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Блюдо") {
                    TextField("Название", text: $entry.name)
                }

                Section("Пищевая ценность") {
                    HStack {
                        Text("Калории")
                        Spacer()
                        Text("\(Int(calculatedCalories.rounded())) ккал")
                            .foregroundStyle(.secondary)
                    }

                    labeledNumberField("Белки", value: $entry.protein, suffix: "г")
                    labeledNumberField("Жиры", value: $entry.fat, suffix: "г")
                    labeledNumberField("Углеводы", value: $entry.carbs, suffix: "г")
                }

                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Text("Удалить запись")
                    }
                }
            }
            .navigationTitle("Редактировать")
            .alert("Удалить запись?", isPresented: $showDeleteConfirm) {
                Button("Удалить", role: .destructive) {
                    onDelete(entry)
                    dismiss()
                }
                Button("Отмена", role: .cancel) { }
            } message: {
                Text("Это действие нельзя отменить.")
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Сохранить") {
                        var updated = entry
                        updated.calories = calculatedCalories
                        onSave(updated)
                        dismiss()
                    }
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
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
            Text(suffix)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview { NavigationStack { HomeView() } }
