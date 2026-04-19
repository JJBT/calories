import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var session: SupabaseSessionStore

    @State private var showSignOutConfirm = false
    @State private var showExportSheet = false
    @State private var exportURL: URL?
    @State private var exportErrorMessage: String?

    private let foodStore = FoodLogStore()

    var body: some View {
        Form {
            Section("Аккаунт") {
                if session.isAuthenticated {
                    if let email = session.userEmail, !email.isEmpty {
                        Text(email)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(session.userId ?? "")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                    }

                    Button("Выйти", role: .destructive) {
                        showSignOutConfirm = true
                    }
                } else {
                    NavigationLink("Войти") {
                        AccountAuthView(mode: .signIn)
                            .environmentObject(session)
                    }
                    NavigationLink("Регистрация") {
                        AccountAuthView(mode: .signUp)
                            .environmentObject(session)
                    }
                }
            }

            Section("Цель по БЖУ") {
                NumericMacroRow(title: "Белки", value: $settings.targetProtein)
                NumericMacroRow(title: "Жиры", value: $settings.targetFat)
                NumericMacroRow(title: "Углеводы", value: $settings.targetCarbs)
            }

            Section("Расчёт калорий") {
                Text("Цель по калориям считается автоматически:")
                    .foregroundStyle(.secondary)
                Text("Б\\*4 + Ж\\*9 + У\\*4 = \(String(settings.targetCalories)) ккал")
                    .font(.system(size: 16, weight: .semibold))
            }

            Section("Дополнительно") {
                Toggle("Показывать среднее КБЖУ за 7 дней", isOn: $settings.show7dAverage)
                Toggle("Заполнять иконку по прогрессу калорий", isOn: $settings.fillBicepProgress)

                Picker("Иконка прогресса", selection: $settings.progressIconRaw) {
                    ForEach(AppSettings.ProgressIcon.allCases, id: \.rawValue) { icon in
                        Label(icon.title, systemImage: icon.symbolName).tag(icon.rawValue)
                    }
                }
            }

            Section("Тема") {
                Picker("Оформление", selection: $settings.themeModeRaw) {
                    ForEach(AppSettings.ThemeMode.allCases, id: \.rawValue) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Button {
                    exportFoodLogCSV()
                } label: {
                    Label("Экспортировать данные (CSV)", systemImage: "square.and.arrow.up")
                }
            }
        }
        .navigationTitle("Настройки")
        .alert("Выйти из аккаунта?", isPresented: $showSignOutConfirm) {
            Button("Выйти", role: .destructive) {
                session.signOut()
            }
            Button("Отмена", role: .cancel) { }
        } message: {
            Text("Вы сможете войти снова в любой момент.")
        }
        .alert("Не удалось экспортировать", isPresented: Binding(
            get: { exportErrorMessage != nil },
            set: { if !$0 { exportErrorMessage = nil } }
        )) {
            Button("Ок", role: .cancel) {
                exportErrorMessage = nil
            }
        } message: {
            Text(exportErrorMessage ?? "")
        }
        .sheet(isPresented: $showExportSheet, onDismiss: {
            exportURL = nil
        }) {
            if let exportURL {
                ShareSheet(activityItems: [exportURL])
            }
        }
    }

    private func exportFoodLogCSV() {
        let days = foodStore.loadAllLocalDays()
        let csv = buildCSV(days: days)
        let fileName = "calories-export-\(timestampString()).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            exportURL = url
            showExportSheet = true
        } catch {
            exportErrorMessage = "Не удалось создать CSV-файл."
        }
    }

    private func buildCSV(days: [(dayKey: String, entries: [FoodEntry])]) -> String {
        var lines: [String] = []
        lines.append("date,food,calories,protein,fat,carbs,daily_calories,daily_protein,daily_fat,daily_carbs")

        for day in days {
            let totalCalories = day.entries.reduce(0) { $0 + $1.calories }
            let totalProtein = day.entries.reduce(0) { $0 + $1.protein }
            let totalFat = day.entries.reduce(0) { $0 + $1.fat }
            let totalCarbs = day.entries.reduce(0) { $0 + $1.carbs }

            for entry in day.entries {
                lines.append(
                    [
                        csvEscape(day.dayKey),
                        csvEscape(entry.name),
                        csvNumber(entry.calories),
                        csvNumber(entry.protein),
                        csvNumber(entry.fat),
                        csvNumber(entry.carbs),
                        csvNumber(totalCalories),
                        csvNumber(totalProtein),
                        csvNumber(totalFat),
                        csvNumber(totalCarbs)
                    ].joined(separator: ",")
                )
            }
        }

        return lines.joined(separator: "\n")
    }

    private func csvEscape(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private func csvNumber(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }

    private func timestampString(now: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: now)
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private enum AccountAuthMode {
    case signIn
    case signUp

    var title: String {
        switch self {
        case .signIn: return "Вход"
        case .signUp: return "Регистрация"
        }
    }

    var actionTitle: String {
        switch self {
        case .signIn: return "Войти"
        case .signUp: return "Создать аккаунт"
        }
    }
}

private struct AccountAuthView: View {
    @EnvironmentObject private var session: SupabaseSessionStore
    @Environment(\.dismiss) private var dismiss

    let mode: AccountAuthMode

    @State private var email = ""
    @State private var password = ""
    @State private var loading = false

    var canSubmit: Bool {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode == .signUp {
            return !e.isEmpty && password.count >= 6
        }
        return !e.isEmpty && !password.isEmpty
    }

    var body: some View {
        Form {
            Section {
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
            }

            Section {
                Button(mode.actionTitle) {
                    Task {
                        loading = true
                        if mode == .signUp {
                            await session.signUp(email: email, password: password)
                        } else {
                            await session.signIn(email: email, password: password)
                        }
                        loading = false
                        if session.isAuthenticated {
                            dismiss()
                        }
                    }
                }
                .disabled(loading || !canSubmit)
            }

            if let err = session.authError, !err.isEmpty {
                Section {
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(mode.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct NumericMacroRow: View {
    let title: String
    @Binding var value: Double

    @State private var text: String = ""

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0", text: $text)
                .keyboardType(.asciiCapableNumberPad)
                .textContentType(.oneTimeCode)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
                .onChange(of: text) { _, newValue in
                    let digits = newValue.filter { $0.isNumber }
                    if digits != newValue { text = digits }
                    value = Double(Int(digits) ?? 0)
                }
                .onAppear {
                    text = String(Int(value))
                }
            Text("г")
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environmentObject(AppSettings())
            .environmentObject(SupabaseSessionStore.shared)
    }
}
