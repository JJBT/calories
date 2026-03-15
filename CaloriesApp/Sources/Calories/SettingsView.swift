import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var session: SupabaseSessionStore

    @State private var showSignOutConfirm = false

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
    }
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
