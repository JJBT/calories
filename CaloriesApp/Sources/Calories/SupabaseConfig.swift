import Foundation

enum SupabaseConfig {
    static var projectURL: URL? {
        if let v = ProcessInfo.processInfo.environment["SUPABASE_URL"], let u = URL(string: v), !v.isEmpty { return u }
        if let v = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
           let u = URL(string: v), !v.isEmpty { return u }
        return nil
    }

    static var publishableKey: String {
        if let v = ProcessInfo.processInfo.environment["SUPABASE_PUBLISHABLE_KEY"], !v.isEmpty { return v }
        if let v = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_PUBLISHABLE_KEY") as? String, !v.isEmpty { return v }
        return ""
    }

    static var redirectURL: URL? {
        if let v = ProcessInfo.processInfo.environment["SUPABASE_REDIRECT_URL"], let u = URL(string: v), !v.isEmpty { return u }
        if let v = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_REDIRECT_URL") as? String,
           let u = URL(string: v), !v.isEmpty { return u }
        return nil
    }

    static var isConfigured: Bool {
        projectURL != nil && !publishableKey.isEmpty
    }
}
