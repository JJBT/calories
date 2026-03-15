import Foundation
import UIKit

/// Минимальный клиент под OpenAI:
/// - Responses API (мультимодал: текст + картинки)
/// - Audio Transcriptions API (голос → текст)
final class OpenAIClient {
    struct ResponseText: Sendable {
        let text: String
        let rawJSON: String
    }

    enum ClientError: Error, LocalizedError {
        case missingAPIKey
        case timedOut
        case badStatus(Int, String)
        case incompleteResponse(String)
        case decoding(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "OPENAI_API_KEY не задан (xcconfig/Info.plist/env)."
            case .timedOut:
                return "Запрос превысил время ожидания. Повтори ещё раз (веб-поиск иногда отвечает дольше обычного)."
            case .badStatus(let code, let body):
                return "OpenAI error status=\(code): \(body)"
            case .incompleteResponse(let reason):
                return "Ответ модели был обрезан (\(reason)). Повтори запрос ещё раз."
            case .decoding(let msg):
                return "Decoding error: \(msg)"
            }
        }
    }

    private let urlSession: URLSession

    init(urlSession: URLSession? = nil) {
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 120
            cfg.timeoutIntervalForResource = 180
            cfg.waitsForConnectivity = true
            self.urlSession = URLSession(configuration: cfg)
        }
    }

    // MARK: - Responses API

    /// Отправить чат с учётом контекста.
    /// - history: предыдущие сообщения (обычно последние N-1)
    /// - newText/newImages: текущее пользовательское сообщение
    func sendFoodChat(history: [ChatMessage], newText: String, newImages: [UIImage], extraContext: String? = nil) async throws -> ResponseText {
        let input = try buildInput(history: history, newText: newText, newImages: newImages, extraContext: extraContext)
        let useWebSearch = shouldUseWebSearch(newText: newText, newImages: newImages)

        do {
            return try await performResponsesRequest(input: input, useWebSearch: useWebSearch)
        } catch ClientError.timedOut where useWebSearch {
            // Fallback: если веб-поиск завис, повторяем без него, чтобы UX не ломался.
            var fallback = try await performResponsesRequest(input: input, useWebSearch: false)
            fallback = ResponseText(
                text: "⚠️ Веб-поиск не успел ответить, дал оценку без интернета.\n\n" + fallback.text,
                rawJSON: fallback.rawJSON
            )
            return fallback
        }
    }

    /// Потоковая версия ответа (token-by-token), как в ChatGPT.
    func sendFoodChatStreaming(
        history: [ChatMessage],
        newText: String,
        newImages: [UIImage],
        extraContext: String? = nil,
        onDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> ResponseText {
        let input = try buildInput(history: history, newText: newText, newImages: newImages, extraContext: extraContext)
        let useWebSearch = shouldUseWebSearch(newText: newText, newImages: newImages)

        do {
            return try await performStreamingResponsesRequest(input: input, useWebSearch: useWebSearch, onDelta: onDelta)
        } catch ClientError.timedOut where useWebSearch {
            let fallback = try await performResponsesRequest(input: input, useWebSearch: false)
            await onDelta("⚠️ Веб-поиск не успел ответить, дал оценку без интернета.\n\n")
            return ResponseText(
                text: "⚠️ Веб-поиск не успел ответить, дал оценку без интернета.\n\n" + fallback.text,
                rawJSON: fallback.rawJSON
            )
        }
    }

    private func shouldUseWebSearch(newText: String, newImages: [UIImage]) -> Bool {
        // Гибридный режим: инструмент веб-поиска доступен всегда,
        // а решение использовать его принимает модель по системным правилам.
        _ = newText
        _ = newImages
        return true
    }

    private func optimizeForUpload(_ image: UIImage, maxSide: CGFloat = 1280) -> UIImage {
        let src = image.normalizedUp()
        let w = src.size.width
        let h = src.size.height
        guard w > 0, h > 0 else { return src }

        let longest = max(w, h)
        guard longest > maxSide else { return src }

        let scale = maxSide / longest
        let newSize = CGSize(width: floor(w * scale), height: floor(h * scale))

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            src.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    private func buildInput(history: [ChatMessage], newText: String, newImages: [UIImage], extraContext: String?) throws -> [[String: Any]] {
        guard !OpenAIConfig.apiKey.isEmpty else { throw ClientError.missingAPIKey }

        let system = """
Ты — помощник-чат в приложении для трекинга еды.

Важно: сценарии бывают разными.
1) ЛОГИРОВАНИЕ еды (пользователь хочет добавить/исправить запись за сегодня или другой выбранный день).
2) ОБЫЧНЫЙ ВОПРОС (например: «сколько ккал в ...», «что лучше съесть», «поясни БЖУ», и т.д.) без намерения что-то записывать.

Правила ответа:
- Отвечай кратко, структурно, без воды и длинных абзацев.
- Не выдумывай значения. Если данных мало — задай уточняющий вопрос.
- Веб-поиск используй только когда реально нужен: ресторан/бренд/готовое блюдо, низкая уверенность, спорные значения, запрос пользователя на источник/проверку.
- Если блюдо обычное и уверенность достаточная — не используй веб-поиск.

Формат ответа зависит от намерения пользователя:

A) Если это ЛОГИРОВАНИЕ еды:
- Используй формат:
  Итог: <1 строка>
  Калории: <число> ккал
  Б: <г>  Ж: <г>  У: <г>
  Источник: <коротко, 1-2 домена максимум или "без веб-поиска">
  Уверенность: <высокая|средняя|низкая>
- И после обычного ответа добавь в конце в одной строке служебный блок:
  <REGISTRATION_JSON>{...}</REGISTRATION_JSON>
- JSON-схема: {"shouldRegister": boolean, "action": "add"|"update_last"|"update_by_name", "targetName": string|null, "items": [{"name": string, "calories": number, "protein": number, "fat": number, "carbs": number}]}
- shouldRegister=true только если данных достаточно для регистрации.
- Если пользователь просит исправить НЕ последнюю запись за сегодня — action=update_by_name и targetName.
- Если данных мало: shouldRegister=false и items=[].

B) Если это ОБЫЧНЫЙ ВОПРОС (без намерения логировать):
- Отвечай просто и по делу, в свободной краткой форме (без обязательных «Итог/Калории/БЖУ/Источник/Уверенность»).
- НЕ добавляй <REGISTRATION_JSON>.

Ограничение: обычно 3-8 строк, без повторов и без длинных объяснений.
"""

        var input: [[String: Any]] = [
            [
                "role": "system",
                "content": [
                    ["type": "input_text", "text": system]
                ]
            ]
        ]

        let trimmedExtraContext = extraContext?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedExtraContext.isEmpty {
            input.append([
                "role": "system",
                "content": [["type": "input_text", "text": "АКТУАЛЬНЫЙ КОНТЕКСТ ПОЛЬЗОВАТЕЛЯ (факты на сегодня):\n\(trimmedExtraContext)"]]
            ])
        }

        for msg in history where !msg.isPending {
            switch msg.role {
            case .user:
                let t = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { continue }
                input.append([
                    "role": "user",
                    "content": [["type": "input_text", "text": t]]
                ])
            case .assistant:
                let t = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { continue }
                input.append([
                    "role": "assistant",
                    "content": [["type": "output_text", "text": t]]
                ])
            case .system:
                continue
            }
        }

        var content: [[String: Any]] = []
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            content.append(["type": "input_text", "text": trimmed])
        }
        for img in newImages {
            let optimized = optimizeForUpload(img)
            guard let jpeg = optimized.jpegData(compressionQuality: 0.72) else { continue }
            let b64 = jpeg.base64EncodedString()
            let dataURL = "data:image/jpeg;base64,\(b64)"
            content.append([
                "type": "input_image",
                "image_url": dataURL
            ])
        }
        input.append([
            "role": "user",
            "content": content
        ])

        return input
    }

    private func performResponsesRequest(input: [[String: Any]], useWebSearch: Bool) async throws -> ResponseText {
        let req = try makeResponsesRequest(input: input, useWebSearch: useWebSearch, stream: false)
        let startedAt = Date()

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await urlSession.data(for: req)
        } catch {
            if let urlError = error as? URLError, urlError.code == .timedOut {
                throw ClientError.timedOut
            }
            throw error
        }

        let http = resp as? HTTPURLResponse
        let raw = String(data: data, encoding: .utf8) ?? ""
        guard let http else { throw ClientError.badStatus(-1, raw) }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.badStatus(http.statusCode, raw)
        }

        guard let text = Self.extractOutputText(from: data) else {
            let reason = Self.extractIncompleteReason(from: data) ?? "unknown"
            throw ClientError.incompleteResponse(reason)
        }

#if DEBUG
        let totalMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let bodyKB = Int(Double(req.httpBody?.count ?? 0) / 1024.0)
        print("[OpenAIClient] non-stream webSearch=\(useWebSearch) body=\(bodyKB)KB total=\(totalMs)ms")
#endif

        return ResponseText(text: text, rawJSON: raw)
    }

    private func performStreamingResponsesRequest(
        input: [[String: Any]],
        useWebSearch: Bool,
        onDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> ResponseText {
        let req = try makeResponsesRequest(input: input, useWebSearch: useWebSearch, stream: true)
        let startedAt = Date()

        let bytes: URLSession.AsyncBytes
        let resp: URLResponse
        do {
            (bytes, resp) = try await urlSession.bytes(for: req)
        } catch {
            if let urlError = error as? URLError, urlError.code == .timedOut {
                throw ClientError.timedOut
            }
            throw error
        }

        let http = resp as? HTTPURLResponse
        guard let http else { throw ClientError.badStatus(-1, "") }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.badStatus(http.statusCode, "stream request failed")
        }

        var fullText = ""
        var completedText: String?
        var rawEvents: [String] = []
        var firstEventAt: Date?
        var firstDeltaAt: Date?
        var eventCount = 0
        var webEventCount = 0
        var webFirstAt: Date?
        var webLastAt: Date?
        var eventTypeCounts: [String: Int] = [:]
        var firstSeenAtByType: [String: Date] = [:]

        for try await line in bytes.lines {
            if firstEventAt == nil { firstEventAt = Date() }
            guard line.hasPrefix("data:") else { continue }
            let dataLine = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !dataLine.isEmpty else { continue }
            if dataLine == "[DONE]" { break }

            rawEvents.append(String(dataLine))
            eventCount += 1
            guard let eventData = dataLine.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any] else {
                continue
            }

            if let type = obj["type"] as? String {
                eventTypeCounts[type, default: 0] += 1
                if firstSeenAtByType[type] == nil {
                    firstSeenAtByType[type] = Date()
                }

                if type.localizedCaseInsensitiveContains("web_search") {
                    webEventCount += 1
                    let now = Date()
                    if webFirstAt == nil { webFirstAt = now }
                    webLastAt = now
                }
            }

            if let delta = Self.extractStreamingDelta(from: obj), !delta.isEmpty {
                if firstDeltaAt == nil { firstDeltaAt = Date() }
                fullText += delta
                await onDelta(delta)
            }

            if completedText == nil, let fromCompleted = Self.extractCompletedText(from: obj) {
                completedText = fromCompleted
            }

            if let type = obj["type"] as? String, type == "response.failed" {
                let err = (obj["error"] as? [String: Any])?["message"] as? String ?? "unknown"
                throw ClientError.badStatus(http.statusCode, err)
            }
        }

        if fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let completedText,
           !completedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fullText = completedText
            await onDelta(completedText)
        }

        if fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ClientError.incompleteResponse("empty_stream")
        }

#if DEBUG
        let totalMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let firstEventMs = firstEventAt.map { Int($0.timeIntervalSince(startedAt) * 1000) } ?? -1
        let firstDeltaMs = firstDeltaAt.map { Int($0.timeIntervalSince(startedAt) * 1000) } ?? -1
        let bodyKB = Int(Double(req.httpBody?.count ?? 0) / 1024.0)
        let webStartMs = webFirstAt.map { Int($0.timeIntervalSince(startedAt) * 1000) } ?? -1
        let webEndMs = webLastAt.map { Int($0.timeIntervalSince(startedAt) * 1000) } ?? -1
        let webDurationMs = (webFirstAt != nil && webLastAt != nil) ? max(0, webEndMs - webStartMs) : 0

        let topTypes = eventTypeCounts
            .sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value > rhs.value
            }
            .prefix(12)
            .map { key, count -> String in
                let firstMs = firstSeenAtByType[key].map { Int($0.timeIntervalSince(startedAt) * 1000) } ?? -1
                return "\(key)=\(count)@\(firstMs)ms"
            }
            .joined(separator: ", ")

        print("[OpenAIClient] stream webSearch=\(useWebSearch) body=\(bodyKB)KB events=\(eventCount) firstEvent=\(firstEventMs)ms firstDelta=\(firstDeltaMs)ms webEvents=\(webEventCount) webStart=\(webStartMs)ms webEnd=\(webEndMs)ms webDur~\(webDurationMs)ms total=\(totalMs)ms")
        print("[OpenAIClient] stream eventTypes: \(topTypes)")
#endif

        return ResponseText(text: fullText, rawJSON: rawEvents.joined(separator: "\n"))
    }

    private func makeResponsesRequest(input: [[String: Any]], useWebSearch: Bool, stream: Bool) throws -> URLRequest {
        let url = OpenAIConfig.baseURL.appendingPathComponent("responses")

        var body: [String: Any] = [
            "model": OpenAIConfig.model,
            "input": input,
            "text": ["format": ["type": "text"]]
        ]

        if useWebSearch {
            body["tools"] = [["type": "web_search_preview"]]
        }

        if stream {
            body["stream"] = true
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(OpenAIConfig.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private static func extractStreamingDelta(from obj: [String: Any]) -> String? {
        let type = obj["type"] as? String

        if type == "response.output_text.delta", let delta = obj["delta"] as? String {
            return delta
        }

        if let delta = obj["delta"] as? String {
            return delta
        }

        if let deltaObj = obj["delta"] as? [String: Any] {
            if let t = deltaObj["text"] as? String { return t }
            if let t = deltaObj["value"] as? String { return t }
        }

        if let item = obj["item"] as? [String: Any] {
            if let delta = item["delta"] as? String { return delta }
            if let deltaObj = item["delta"] as? [String: Any] {
                if let t = deltaObj["text"] as? String { return t }
                if let t = deltaObj["value"] as? String { return t }
            }
        }

        if let text = obj["text"] as? String, type == "response.output_text" {
            return text
        }

        return nil
    }

    private static func extractCompletedText(from obj: [String: Any]) -> String? {
        guard let type = obj["type"] as? String,
              type == "response.completed",
              let response = obj["response"] as? [String: Any] else {
            return nil
        }

        if let outputText = response["output_text"] as? String,
           !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return outputText
        }

        if let output = response["output"] as? [[String: Any]] {
            var parts: [String] = []
            for item in output {
                if let content = item["content"] as? [[String: Any]] {
                    for block in content {
                        if let t = block["text"] as? String {
                            parts.append(t)
                        } else if let txt = block["text"] as? [String: Any], let v = txt["value"] as? String {
                            parts.append(v)
                        }
                    }
                }
            }
            let joined = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }

        return nil
    }

    private static func extractOutputText(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let v = obj["output_text"] as? String, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return v
        }
        if let output = obj["output"] as? [[String: Any]] {
            var parts: [String] = []
            for item in output {
                if let content = item["content"] as? [[String: Any]] {
                    for block in content {
                        if let type = block["type"] as? String, type.contains("text") {
                            if let t = block["text"] as? String { parts.append(t) }
                            else if let t = (block["text"] as? [String: Any])?["value"] as? String { parts.append(t) }
                        }
                    }
                }
            }
            let joined = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private static func extractIncompleteReason(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let details = obj["incomplete_details"] as? [String: Any],
           let reason = details["reason"] as? String {
            return reason
        }
        if let status = obj["status"] as? String, status == "incomplete" {
            return "incomplete"
        }
        return nil
    }

    // MARK: - Audio Transcriptions

    /// Транскрибация аудио (m4a) через OpenAI.
    func transcribeAudio(fileURL: URL, language: String? = nil) async throws -> String {
        guard !OpenAIConfig.apiKey.isEmpty else { throw ClientError.missingAPIKey }

        let url = OpenAIConfig.baseURL.appendingPathComponent("audio/transcriptions")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(OpenAIConfig.apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: fileURL)
        var form = Data()

        func append(_ s: String) {
            form.append(s.data(using: .utf8)!)
        }

        // model
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(OpenAIConfig.transcriptionModel)\r\n")

        // response_format
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        append("json\r\n")

        // language (optional)
        if let language {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
            append("\(language)\r\n")
        }

        // file
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n")
        append("Content-Type: audio/mp4\r\n\r\n")
        form.append(audioData)
        append("\r\n")

        append("--\(boundary)--\r\n")

        req.httpBody = form

        let (data, resp) = try await urlSession.data(for: req)
        let http = resp as? HTTPURLResponse
        let raw = String(data: data, encoding: .utf8) ?? ""
        guard let http else { throw ClientError.badStatus(-1, raw) }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.badStatus(http.statusCode, raw)
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["text"] as? String else {
            throw ClientError.decoding(raw)
        }
        return text
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
}
