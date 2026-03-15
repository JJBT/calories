import Foundation

/// Конфиг OpenAI (dev). Сейчас ключ и модели читаем из Info.plist / xcconfig.
/// Позже вынесем на серверный прокси.
enum OpenAIConfig {
    /// ВАЖНО: для прода ключ в клиенте держать нельзя. Сейчас это только для отладки.
    static var apiKey: String {
        // 1) пробуем из environment (удобно для превью/тестов)
        if let v = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !v.isEmpty { return v }
        // 2) пробуем из Info.plist (через xcconfig)
        if let v = Bundle.main.object(forInfoDictionaryKey: "OPENAI_API_KEY") as? String, !v.isEmpty { return v }
        return ""
    }

    static var model: String {
        if let v = ProcessInfo.processInfo.environment["OPENAI_MODEL"], !v.isEmpty { return v }
        if let v = Bundle.main.object(forInfoDictionaryKey: "OPENAI_MODEL") as? String, !v.isEmpty { return v }
        return "gpt-5.2"
    }

    static var transcriptionModel: String {
        if let v = ProcessInfo.processInfo.environment["OPENAI_TRANSCRIBE_MODEL"], !v.isEmpty { return v }
        if let v = Bundle.main.object(forInfoDictionaryKey: "OPENAI_TRANSCRIBE_MODEL") as? String, !v.isEmpty { return v }
        return "whisper-1"
    }

    static var baseURL: URL { URL(string: "https://api.openai.com/v1")! }
}
