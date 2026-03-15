import Foundation
import AuthenticationServices
import UIKit

@MainActor
final class SupabaseSessionStore: NSObject, ObservableObject {
    static let shared = SupabaseSessionStore()

    @Published private(set) var accessToken: String?
    @Published private(set) var userId: String?
    @Published private(set) var userEmail: String?
    @Published var authError: String?

    private(set) var refreshToken: String?

    var isAuthenticated: Bool {
        guard let accessToken, let userId else { return false }
        return !accessToken.isEmpty && !userId.isEmpty
    }

    func validateCurrentSession() async {
        guard let token = accessToken,
              !token.isEmpty,
              let base = SupabaseConfig.projectURL else { return }

        do {
            var req = URLRequest(url: base.appendingPathComponent("/auth/v1/user"))
            req.httpMethod = "GET"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")

            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 401 || http.statusCode == 403 {
                if await refreshSession() {
                    return
                }
                signOut()
                authError = "Сессия истекла. Войди в аккаунт снова."
            }
        } catch {
            // network hiccup: keep current session, don't force sign out
        }
    }

    private func refreshSession() async -> Bool {
        guard let base = SupabaseConfig.projectURL,
              !SupabaseConfig.publishableKey.isEmpty,
              let refreshToken,
              !refreshToken.isEmpty else { return false }

        do {
            var components = URLComponents(url: base.appendingPathComponent("/auth/v1/token"), resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
            guard let url = components?.url else { return false }

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])

            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return false
            }

            let session = try JSONDecoder().decode(SupabaseAuthSession.self, from: data)
            guard let token = session.access_token, !token.isEmpty else { return false }
            setSession(token: token, refreshToken: session.refresh_token, userId: session.user.id, email: session.user.email)
            authError = nil
            return true
        } catch {
            return false
        }
    }

    private let defaults = UserDefaults.standard
    private let tokenKey = "supabase.accessToken"
    private let refreshTokenKey = "supabase.refreshToken"
    private let userIdKey = "supabase.userId"
    private let userEmailKey = "supabase.userEmail"
    private var oauthSession: ASWebAuthenticationSession?

    private override init() {
        accessToken = defaults.string(forKey: tokenKey)
        refreshToken = defaults.string(forKey: refreshTokenKey)
        userId = defaults.string(forKey: userIdKey)
        userEmail = defaults.string(forKey: userEmailKey)
        super.init()
    }

    func signOut() {
        accessToken = nil
        refreshToken = nil
        userId = nil
        userEmail = nil
        defaults.removeObject(forKey: tokenKey)
        defaults.removeObject(forKey: refreshTokenKey)
        defaults.removeObject(forKey: userIdKey)
        defaults.removeObject(forKey: userEmailKey)
        authError = nil
        NotificationCenter.default.post(name: .supabaseSessionDidChange, object: nil)
        NotificationCenter.default.post(name: .foodLogDidChange, object: nil)
        NotificationCenter.default.post(name: .favoritesDidChange, object: nil)
    }

    func signUp(email: String, password: String) async {
        let normalizedEmail = normalizeEmail(email)
        let normalizedPassword = normalizePassword(password)
        await authRequest(path: "/auth/v1/signup", payload: ["email": normalizedEmail, "password": normalizedPassword])
    }

    func signIn(email: String, password: String) async {
        let normalizedEmail = normalizeEmail(email)
        let normalizedPassword = normalizePassword(password)

        guard let base = SupabaseConfig.projectURL else {
            authError = "Supabase URL not configured"
            return
        }
        guard !SupabaseConfig.publishableKey.isEmpty else {
            authError = "Supabase publishable key not configured"
            return
        }

        do {
            var components = URLComponents(url: base.appendingPathComponent("/auth/v1/token"), resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "grant_type", value: "password")]
            guard let url = components?.url else { return }

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["email": normalizedEmail, "password": normalizedPassword])

            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                authError = makeAuthErrorMessage(data: data, statusCode: (response as? HTTPURLResponse)?.statusCode, context: .signIn)
                return
            }

            let session = try JSONDecoder().decode(SupabaseAuthSession.self, from: data)
            guard let token = session.access_token, !token.isEmpty else {
                authError = "Не удалось войти. Попробуй ещё раз."
                return
            }
            setSession(token: token, refreshToken: session.refresh_token, userId: session.user.id, email: session.user.email)
            authError = nil
        } catch {
            authError = error.localizedDescription
        }
    }

    func signInWithGoogle() async {
        guard let base = SupabaseConfig.projectURL else {
            authError = "Supabase URL not configured"
            return
        }
        guard !SupabaseConfig.publishableKey.isEmpty else {
            authError = "Supabase publishable key not configured"
            return
        }

        let redirect = SupabaseConfig.redirectURL ?? URL(string: "calories://auth-callback")!
        guard let callbackScheme = redirect.scheme else {
            authError = "Invalid redirect URL scheme"
            return
        }

        do {
            var components = URLComponents(url: base.appendingPathComponent("/auth/v1/authorize"), resolvingAgainstBaseURL: false)
            components?.queryItems = [
                URLQueryItem(name: "provider", value: "google"),
                URLQueryItem(name: "redirect_to", value: redirect.absoluteString)
            ]
            guard let authURL = components?.url else {
                authError = "Failed to build Google auth URL"
                return
            }

            let callbackURL = try await beginOAuth(url: authURL, callbackScheme: callbackScheme)
            guard let tokens = extractAuthTokens(from: callbackURL), !tokens.accessToken.isEmpty else {
                authError = "Google sign-in returned no access token"
                return
            }

            let user = try await fetchCurrentUser(accessToken: tokens.accessToken, base: base)
            setSession(token: tokens.accessToken, refreshToken: tokens.refreshToken, userId: user.id, email: user.email)
            authError = nil
        } catch {
            authError = error.localizedDescription
        }
    }

    private func authRequest(path: String, payload: [String: Any]) async {
        guard let base = SupabaseConfig.projectURL else {
            authError = "Supabase URL not configured"
            return
        }
        guard !SupabaseConfig.publishableKey.isEmpty else {
            authError = "Supabase publishable key not configured"
            return
        }

        do {
            var req = URLRequest(url: base.appendingPathComponent(path))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                authError = makeAuthErrorMessage(data: data, statusCode: (response as? HTTPURLResponse)?.statusCode, context: .signUp)
                return
            }

            // На signup Supabase может вернуть ответ без access_token (например, когда нужна верификация почты).
            if let session = try? JSONDecoder().decode(SupabaseAuthSession.self, from: data),
               let token = session.access_token,
               !token.isEmpty {
                setSession(token: token, refreshToken: session.refresh_token, userId: session.user.id, email: session.user.email)
                authError = nil
                return
            }

            if let signUp = try? JSONDecoder().decode(SupabaseSignUpResponse.self, from: data),
               let user = signUp.user {
                authError = "Аккаунт создан. Теперь войди с email и паролем."
                if let email = user.email, !email.isEmpty {
                    userEmail = email
                    defaults.set(email, forKey: userEmailKey)
                }
                return
            }

            authError = "Аккаунт создан. Теперь войди с email и паролем."
        } catch {
            authError = "Не удалось зарегистрироваться. Попробуй ещё раз."
        }
    }

    private func setSession(token: String, refreshToken: String?, userId: String, email: String?) {
        self.accessToken = token
        self.refreshToken = refreshToken
        self.userId = userId
        self.userEmail = email
        defaults.set(token, forKey: tokenKey)
        if let refreshToken, !refreshToken.isEmpty {
            defaults.set(refreshToken, forKey: refreshTokenKey)
        } else {
            defaults.removeObject(forKey: refreshTokenKey)
        }
        defaults.set(userId, forKey: userIdKey)
        if let email, !email.isEmpty {
            defaults.set(email, forKey: userEmailKey)
        } else {
            defaults.removeObject(forKey: userEmailKey)
        }
        NotificationCenter.default.post(name: .supabaseSessionDidChange, object: nil)
        NotificationCenter.default.post(name: .foodLogDidChange, object: nil)
        NotificationCenter.default.post(name: .favoritesDidChange, object: nil)
    }

    private func beginOAuth(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: NSError(domain: "SupabaseAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: "No callback URL from OAuth"]))
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = self
            self.oauthSession = session
            session.start()
        }
    }

    private func extractAuthTokens(from callbackURL: URL) -> OAuthCallbackTokens? {
        if let fragment = callbackURL.fragment {
            let items = fragment
                .split(separator: "&")
                .map(String.init)
                .compactMap { part -> (String, String)? in
                    let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
                    guard kv.count == 2 else { return nil }
                    return (kv[0], kv[1].removingPercentEncoding ?? kv[1])
                }
            let dict = Dictionary(uniqueKeysWithValues: items)
            if let accessToken = dict["access_token"], !accessToken.isEmpty {
                let refreshToken = dict["refresh_token"]
                return OAuthCallbackTokens(accessToken: accessToken, refreshToken: refreshToken)
            }
        }

        if let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) {
            let accessToken = components.queryItems?.first(where: { $0.name == "access_token" })?.value
            if let accessToken, !accessToken.isEmpty {
                let refreshToken = components.queryItems?.first(where: { $0.name == "refresh_token" })?.value
                return OAuthCallbackTokens(accessToken: accessToken, refreshToken: refreshToken)
            }
        }

        return nil
    }

    private func fetchCurrentUser(accessToken: String, base: URL) async throws -> SupabaseUserProfile {
        var req = URLRequest(url: base.appendingPathComponent("/auth/v1/user"))
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "SupabaseAuth", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "Failed to fetch user profile"])
        }

        return try JSONDecoder().decode(SupabaseUserProfile.self, from: data)
    }

    private enum AuthContext {
        case signIn
        case signUp
    }

    private func normalizeEmail(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalizePassword(_ value: String) -> String {
        value.trimmingCharacters(in: .newlines)
    }

    private func makeAuthErrorMessage(data: Data, statusCode: Int?, context: AuthContext) -> String {
        let raw = String(data: data, encoding: .utf8) ?? ""

        let parsed = (try? JSONDecoder().decode(SupabaseAuthError.self, from: data))
        let msg = (parsed?.msg ?? parsed?.error_description ?? parsed?.error ?? raw).lowercased()
        let code = (parsed?.code ?? parsed?.error_code ?? "").lowercased()

        if code.contains("invalid_credentials") || msg.contains("invalid login credentials") {
            return "Неверный email или пароль. Проверь данные и попробуй снова."
        }
        if msg.contains("email not confirmed") || code.contains("email_not_confirmed") {
            return "Почта не подтверждена. Проверь письмо и подтвердите email."
        }
        if msg.contains("user already registered") || msg.contains("already registered") {
            return "Пользователь с таким email уже существует. Попробуй войти."
        }
        if msg.contains("password") && msg.contains("least") {
            return "Пароль слишком слабый. Используй более длинный пароль."
        }
        if statusCode == 429 {
            return "Слишком много попыток. Подожди немного и попробуй снова."
        }

        switch context {
        case .signIn:
            return "Не удалось войти. Попробуй ещё раз."
        case .signUp:
            return "Не удалось зарегистрироваться. Проверь данные и попробуй снова."
        }
    }
}

private struct OAuthCallbackTokens {
    let accessToken: String
    let refreshToken: String?
}

private struct SupabaseAuthSession: Decodable {
    struct User: Decodable {
        let id: String
        let email: String?
    }
    let access_token: String?
    let refresh_token: String?
    let user: User
}

private struct SupabaseSignUpResponse: Decodable {
    let user: SupabaseAuthSession.User?
}

private struct SupabaseUserProfile: Decodable {
    let id: String
    let email: String?
}

private struct SupabaseAuthError: Decodable {
    let code: String?
    let error_code: String?
    let msg: String?
    let error: String?
    let error_description: String?
}

extension SupabaseSessionStore: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        DispatchQueue.main.sync {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first(where: { $0.isKeyWindow }) ?? ASPresentationAnchor()
        }
    }
}
