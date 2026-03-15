import Foundation
import SwiftUI
import UIKit

@MainActor
final class FoodChatViewModel: ObservableObject {
    static let shared = FoodChatViewModel()
    @Published var messages: [ChatMessage] = []
    @Published var composerText: String = ""
    @Published var composerImages: [UIImage] = []
    @Published var isSending: Bool = false
    @Published var isTranscribing: Bool = false
    @Published var lastError: String?

    let audioRecorder = AudioRecorder()
    private let openAI = OpenAIClient()
    private let store = ChatHistoryStore()
    private let foodStore = FoodLogStore()
    private let favoritesStore = FavoritesStore()

    @AppStorage("app.targetProtein") private var targetProtein: Double = 158
    @AppStorage("app.targetFat") private var targetFat: Double = 58
    @AppStorage("app.targetCarbs") private var targetCarbs: Double = 236

    private var dayKey: String = ""
    private var pendingRegistration: RegistrationPayload?
    private var pendingRegistrationByDay: [String: RegistrationPayload] = [:]
    private var messagesByDay: [String: [ChatMessage]] = [:]
    private var activeSendTask: Task<Void, Never>?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    init() {
        ensureLoaded(for: store.effectiveToday())
    }

    func ensureLoaded(for selectedDay: Date) {
        let key = store.dayKey(for: selectedDay)
        guard key != dayKey else { return }
        dayKey = key

        if let cached = messagesByDay[key] {
            messages = cached
        } else {
            let loaded = store.load(dayKey: key)
            if loaded.isEmpty {
                messages = [
                    ChatMessage(role: .assistant, text: "Опишите вашу еду — голосом или текстом. Можно прикрепить несколько фото (упаковка, состав, тарелка).")
                ]
                store.save(messages: messages, dayKey: key)
            } else {
                messages = loaded
            }
            messagesByDay[key] = messages
        }

        pendingRegistration = pendingRegistrationByDay[key]

        let draft = store.loadDraft(dayKey: key)
        composerText = draft.text
        composerImages = draft.images
    }

    func addImages(_ imgs: [UIImage]) {
        composerImages.append(contentsOf: imgs)
        persistDraft()
    }

    func persistDraft() {
        guard !dayKey.isEmpty else { return }
        store.saveDraft(text: composerText, images: composerImages, dayKey: dayKey)
    }

    func removeComposerImage(at index: Int) {
        guard composerImages.indices.contains(index) else { return }
        composerImages.remove(at: index)
        persistDraft()
    }

    func toggleRecording() async {
        lastError = nil
        if audioRecorder.isRecording {
            audioRecorder.stop()
            guard let url = audioRecorder.lastFileURL else { return }
            await transcribeAndAppend(url: url)
        } else {
            let ok = await audioRecorder.requestPermission()
            guard ok else {
                lastError = "Нет доступа к микрофону. Разреши микрофон в Settings."
                return
            }
            do {
                try audioRecorder.start()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func transcribeAndAppend(url: URL) async {
        isTranscribing = true
        defer { isTranscribing = false }

        do {
            let text = try await openAI.transcribeAudio(fileURL: url, language: "ru")
            if composerText.isEmpty {
                composerText = text
            } else {
                composerText += " " + text
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func sendInBackground(selectedDay: Date) {
        guard activeSendTask == nil else { return }
        let day = selectedDay
        beginBackgroundTaskIfNeeded()
        activeSendTask = Task { [weak self] in
            guard let self else { return }
            await self.send(selectedDay: day)
            self.activeSendTask = nil
            self.endBackgroundTaskIfNeeded()
        }
    }

    func send(selectedDay: Date) async {
        ensureLoaded(for: selectedDay)

        let requestDayKey = dayKey
        var workingMessages = messagesByDay[requestDayKey] ?? messages

        lastError = nil
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let imgs = composerImages
        guard !text.isEmpty || !imgs.isEmpty else { return }

        if let pending = pendingRegistrationByDay[requestDayKey], imgs.isEmpty {
            if isAffirmative(text) {
                let registeredText = applyRegistration(payload: pending, selectedDay: selectedDay)
                pendingRegistrationByDay[requestDayKey] = nil
                if requestDayKey == dayKey { pendingRegistration = nil }

                workingMessages.append(ChatMessage(role: .assistant, text: registeredText))
                messagesByDay[requestDayKey] = workingMessages
                if requestDayKey == dayKey { messages = workingMessages }
                store.save(messages: workingMessages, dayKey: requestDayKey)

                NotificationCenter.default.post(
                    name: .foodEntryRegistered,
                    object: nil,
                    userInfo: ["text": registeredText]
                )

                composerText = ""
                composerImages = []
                persistDraft()
                return
            } else if isNegativeOrEdit(text) {
                pendingRegistrationByDay[requestDayKey] = nil
                if requestDayKey == dayKey { pendingRegistration = nil }
                // продолжаем обычный диалог, чтобы пользователь мог уточнить данные
            }
        }

        guard !OpenAIConfig.apiKey.isEmpty else {
            lastError = "OPENAI_API_KEY не задан. Добавь в Config.xcconfig/Info.plist."
            return
        }

        let historyTail = Array(workingMessages
            .filter { !$0.isPending }
            .filter { $0.role != .system }
            .suffix(8))

        let userMsg = ChatMessage(role: .user, text: text, images: imgs)
        workingMessages.append(userMsg)
        messagesByDay[requestDayKey] = workingMessages
        if requestDayKey == dayKey { messages = workingMessages }
        store.save(messages: workingMessages, dayKey: requestDayKey)

        composerText = ""
        composerImages = []
        persistDraft()

        let pending = ChatMessage(role: .assistant, text: "", images: [], isPending: true)
        workingMessages.append(pending)
        messagesByDay[requestDayKey] = workingMessages
        if requestDayKey == dayKey { messages = workingMessages }

        let llmContext = buildLLMContext(selectedDay: selectedDay)

        isSending = true
        do {
            let resp = try await openAI.sendFoodChatStreaming(
                history: historyTail,
                newText: userMsg.text,
                newImages: userMsg.images,
                extraContext: llmContext,
                onDelta: { delta in
                    await MainActor.run {
                        self.appendStreamingDelta(delta, pendingID: pending.id, dayKey: requestDayKey)
                    }
                }
            )
            let parsed = parseRegistrationPayload(from: resp.text)

            var updated = messagesByDay[requestDayKey] ?? workingMessages
            if let idx = updated.lastIndex(where: { $0.id == pending.id }) {
                updated[idx].text = parsed.cleanText
                updated[idx].isPending = false
            }

            if let payload = parsed.payload, payload.shouldRegister, !payload.items.isEmpty {
                pendingRegistrationByDay[requestDayKey] = payload
                if requestDayKey == dayKey { pendingRegistration = payload }

                let summary = payload.items.enumerated().map { idx, item in
                    "\(idx + 1). \(item.name)\n   \(Int(item.calories.rounded())) ккал • Б \(Int(item.protein.rounded())) • Ж \(Int(item.fat.rounded())) • У \(Int(item.carbs.rounded()))"
                }
                .joined(separator: "\n\n")

                let confirmText = "Проверь, всё ли верно перед регистрацией:\n\n\(summary)\n\nОтветь:\n• да — зарегистрировать\n• поменять — уточнить"
                updated.append(ChatMessage(role: .assistant, text: confirmText))
            }

            messagesByDay[requestDayKey] = updated
            if requestDayKey == dayKey { messages = updated }
            store.save(messages: updated, dayKey: requestDayKey)
        } catch {
            do {
                let resp = try await openAI.sendFoodChat(history: historyTail, newText: userMsg.text, newImages: userMsg.images, extraContext: llmContext)
                let parsed = parseRegistrationPayload(from: resp.text)

                var updated = messagesByDay[requestDayKey] ?? workingMessages
                if let idx = updated.lastIndex(where: { $0.id == pending.id }) {
                    updated[idx].text = parsed.cleanText
                    updated[idx].isPending = false
                }

                if let payload = parsed.payload, payload.shouldRegister, !payload.items.isEmpty {
                    pendingRegistrationByDay[requestDayKey] = payload
                    if requestDayKey == dayKey { pendingRegistration = payload }

                    let summary = payload.items.enumerated().map { idx, item in
                        "\(idx + 1). \(item.name)\n   \(Int(item.calories.rounded())) ккал • Б \(Int(item.protein.rounded())) • Ж \(Int(item.fat.rounded())) • У \(Int(item.carbs.rounded()))"
                    }
                    .joined(separator: "\n\n")

                    let confirmText = "Проверь, всё ли верно перед регистрацией:\n\n\(summary)\n\nОтветь:\n• да — зарегистрировать\n• поменять — уточнить"
                    updated.append(ChatMessage(role: .assistant, text: confirmText))
                }

                messagesByDay[requestDayKey] = updated
                if requestDayKey == dayKey { messages = updated }
                store.save(messages: updated, dayKey: requestDayKey)
            } catch {
                var updated = messagesByDay[requestDayKey] ?? workingMessages
                updated.removeAll { $0.id == pending.id }
                messagesByDay[requestDayKey] = updated
                if requestDayKey == dayKey {
                    messages = updated
                    lastError = error.localizedDescription
                }
                store.save(messages: updated, dayKey: requestDayKey)
            }
        }
        isSending = false
    }

    private func appendStreamingDelta(_ delta: String, pendingID: UUID, dayKey: String) {
        guard !delta.isEmpty else { return }
        var updated = messagesByDay[dayKey] ?? messages
        guard let idx = updated.lastIndex(where: { $0.id == pendingID }) else { return }
        updated[idx].text += delta
        messagesByDay[dayKey] = updated
        if dayKey == self.dayKey {
            messages = updated
        }
    }

    private func beginBackgroundTaskIfNeeded() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "FoodChatSend") { [weak self] in
            self?.activeSendTask?.cancel()
            self?.endBackgroundTaskIfNeeded()
        }
    }

    private func endBackgroundTaskIfNeeded() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func buildLLMContext(selectedDay: Date) -> String {
        let dayKey = foodStore.dayKey(for: selectedDay)
        let todayEntries = foodStore.load(dayKey: dayKey).sorted { $0.createdAt < $1.createdAt }

        let consumedCalories = Int(todayEntries.reduce(0) { $0 + $1.calories }.rounded())
        let consumedProtein = Int(todayEntries.reduce(0) { $0 + $1.protein }.rounded())
        let consumedFat = Int(todayEntries.reduce(0) { $0 + $1.fat }.rounded())
        let consumedCarbs = Int(todayEntries.reduce(0) { $0 + $1.carbs }.rounded())

        let targetKcal = Int((targetProtein * 4 + targetFat * 9 + targetCarbs * 4).rounded())
        let targetP = Int(targetProtein.rounded())
        let targetF = Int(targetFat.rounded())
        let targetC = Int(targetCarbs.rounded())

        let todayList = Array(todayEntries.prefix(6))

        let fallbackRecent: [FoodEntry]
        if todayList.count < 6 {
            fallbackRecent = recentEntriesFallback(excludingDay: selectedDay, excluding: todayEntries)
        } else {
            fallbackRecent = []
        }

        let favorites = Array(favoritesStore.load().prefix(6))

        var lines: [String] = []
        lines.append("Цель КБЖУ на день: \(targetKcal) ккал; Б \(targetP) г; Ж \(targetF) г; У \(targetC) г")
        lines.append("Съедено сегодня: \(consumedCalories) ккал; Б \(consumedProtein) г; Ж \(consumedFat) г; У \(consumedCarbs) г")

        lines.append("Сегодняшние блюда (\(todayEntries.count) шт):")
        if todayEntries.isEmpty {
            lines.append("- нет записей")
        } else {
            for (idx, entry) in todayEntries.enumerated() {
                lines.append("- \(idx + 1). \(formatEntry(entry))")
            }
        }

        lines.append("6 последних избранных блюд:")
        if favorites.isEmpty {
            lines.append("- нет")
        } else {
            for (idx, item) in favorites.enumerated() {
                lines.append("- \(idx + 1). \(formatFavorite(item))")
            }
        }

        if !fallbackRecent.isEmpty {
            lines.append("Дополнение из недавних (чтобы добрать до 6, если сегодня < 6):")
            for (idx, entry) in fallbackRecent.prefix(max(0, 6 - todayList.count)).enumerated() {
                lines.append("- \(idx + 1). \(formatEntry(entry))")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func recentEntriesFallback(excludingDay selectedDay: Date, excluding todayEntries: [FoodEntry]) -> [FoodEntry] {
        let calendar = Calendar.current
        let minDate = calendar.date(byAdding: .day, value: -28, to: selectedDay) ?? selectedDay
        let excludedSignatures = Set(todayEntries.map { entrySignature($0) })

        var collected: [FoodEntry] = []
        var seen = Set<String>()

        for offset in 1...28 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: selectedDay) else { continue }
            if day < minDate { continue }

            let dayKey = foodStore.dayKey(for: day)
            let entries = foodStore.load(dayKey: dayKey)

            for entry in entries.sorted(by: { $0.createdAt > $1.createdAt }) {
                let sig = entrySignature(entry)
                if excludedSignatures.contains(sig) || seen.contains(sig) { continue }
                seen.insert(sig)
                collected.append(entry)
                if collected.count >= 6 { return collected }
            }
        }

        return collected
    }

    private func entrySignature(_ entry: FoodEntry) -> String {
        "\(entry.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))|\(Int(entry.calories.rounded()))|\(Int(entry.protein.rounded()))|\(Int(entry.fat.rounded()))|\(Int(entry.carbs.rounded()))"
    }

    private func formatEntry(_ entry: FoodEntry) -> String {
        "\(entry.name) — \(Int(entry.calories.rounded())) ккал, Б \(Int(entry.protein.rounded())) г, Ж \(Int(entry.fat.rounded())) г, У \(Int(entry.carbs.rounded())) г"
    }

    private func formatFavorite(_ item: FavoriteFood) -> String {
        "\(item.name) — \(Int(item.calories.rounded())) ккал, Б \(Int(item.protein.rounded())) г, Ж \(Int(item.fat.rounded())) г, У \(Int(item.carbs.rounded())) г"
    }

    private func applyRegistration(payload: RegistrationPayload, selectedDay: Date) -> String {
        guard payload.shouldRegister, !payload.items.isEmpty else {
            return "Не получилось зарегистрировать: недостаточно данных."
        }

        let dayKey = foodStore.dayKey(for: selectedDay)
        var entries = foodStore.load(dayKey: dayKey)

        let newItems = payload.items.map {
            FoodEntry(
                name: $0.name,
                calories: $0.calories,
                protein: $0.protein,
                fat: $0.fat,
                carbs: $0.carbs
            )
        }

        if payload.action == "update_last", !entries.isEmpty {
            if newItems.count == 1 {
                let existing = entries.removeLast()
                let i = newItems[0]
                entries.append(FoodEntry(id: existing.id, name: i.name, calories: i.calories, protein: i.protein, fat: i.fat, carbs: i.carbs, createdAt: existing.createdAt))
            } else {
                let replaceCount = min(newItems.count, entries.count)
                entries.removeLast(replaceCount)
                entries.append(contentsOf: newItems)
            }
        } else if payload.action == "update_by_name", let target = payload.targetName?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty {
            if let idx = entries.lastIndex(where: { $0.name.localizedCaseInsensitiveContains(target) || target.localizedCaseInsensitiveContains($0.name) }) {
                let base = entries[idx]
                let i = newItems.first ?? FoodEntry(name: base.name, calories: base.calories, protein: base.protein, fat: base.fat, carbs: base.carbs)
                entries[idx] = FoodEntry(id: base.id, name: i.name, calories: i.calories, protein: i.protein, fat: i.fat, carbs: i.carbs, createdAt: base.createdAt)
            } else {
                entries.append(contentsOf: newItems)
            }
        } else {
            entries.append(contentsOf: newItems)
        }

        foodStore.save(entries, dayKey: dayKey)
        NotificationCenter.default.post(name: .foodLogDidChange, object: nil)

        if let first = newItems.first {
            if newItems.count == 1 {
                return "\(first.name) зарегистрировано"
            }
            return "Зарегистрировано \(newItems.count) блюд (первое: \(first.name))"
        }
        return "Запись зарегистрирована"
    }

    private func isAffirmative(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let yesWords = ["да", "ок", "окей", "ага", "подтверждаю", "регистрируй", "сохрани", "добавляй"]
        return yesWords.contains { t == $0 || t.contains($0) }
    }

    private func isNegativeOrEdit(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let words = ["нет", "не", "поменяй", "измени", "исправь", "уточню", "стоп"]
        return words.contains { t == $0 || t.contains($0) }
    }

    private struct RegistrationPayload: Decodable {
        struct Item: Decodable {
            let name: String
            let calories: Double
            let protein: Double
            let fat: Double
            let carbs: Double
        }
        let shouldRegister: Bool
        let action: String
        let targetName: String?
        let items: [Item]
    }

    private func parseRegistrationPayload(from text: String) -> (cleanText: String, payload: RegistrationPayload?) {
        // 1) Основной формат: <REGISTRATION_JSON>{...}</REGISTRATION_JSON>
        if let startTagRange = text.range(of: "<REGISTRATION_JSON>") {
            let jsonStart = startTagRange.upperBound
            let tail = text[jsonStart...]

            // Модель иногда ломает закрывающий тег (например `</REGISTRATION_JSON}` или без `>`).
            let endCandidates = ["</REGISTRATION_JSON>", "</REGISTRATION_JSON}", "</REGISTRATION_JSON"]
            let endTagRange = endCandidates
                .compactMap { marker in
                    tail.range(of: marker).map { (range: $0, marker: marker) }
                }
                .min { $0.range.lowerBound < $1.range.lowerBound }

            let jsonEnd = endTagRange?.range.lowerBound

            let jsonString: String
            let clean: String

            if let jsonEnd {
                jsonString = String(text[jsonStart..<jsonEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
                let removeRange = startTagRange.lowerBound..<(endTagRange!.range.upperBound)
                clean = String(text.replacingCharacters(in: removeRange, with: "")).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                let extracted = extractFirstJSONObject(from: String(tail))
                jsonString = extracted?.json.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if let extracted {
                    let startOffset = text.distance(from: text.startIndex, to: jsonStart)
                    let absStart = text.index(text.startIndex, offsetBy: startOffset + extracted.start)
                    let absEnd = text.index(absStart, offsetBy: extracted.length)
                    let removeRange = startTagRange.lowerBound..<absEnd
                    clean = String(text.replacingCharacters(in: removeRange, with: "")).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    clean = text
                }
            }

            if let data = jsonString.data(using: .utf8),
               let payload = try? JSONDecoder().decode(RegistrationPayload.self, from: data) {
                return (clean.isEmpty ? text : clean, payload)
            }
            return (clean, nil)
        }

        // 2) Fallback-формат: "REGISTRATION_JSON: {...}" (без тегов)
        let fallbackMarkers = ["REGISTRATION_JSON:", "REGISTRATION_JSON", "Registration_JSON:", "registration_json:"]
        if let markerRange = fallbackMarkers
            .compactMap({ marker in text.range(of: marker) })
            .min(by: { $0.lowerBound < $1.lowerBound }) {
            let tail = String(text[markerRange.upperBound...])
            if let extracted = extractFirstJSONObject(from: tail),
               let data = extracted.json.data(using: .utf8),
               let payload = try? JSONDecoder().decode(RegistrationPayload.self, from: data) {
                let startOffset = text.distance(from: text.startIndex, to: markerRange.upperBound)
                let absStart = text.index(text.startIndex, offsetBy: startOffset + extracted.start)
                let absEnd = text.index(absStart, offsetBy: extracted.length)
                let removeRange = markerRange.lowerBound..<absEnd
                let clean = String(text.replacingCharacters(in: removeRange, with: "")).trimmingCharacters(in: .whitespacesAndNewlines)
                return (clean.isEmpty ? text : clean, payload)
            }
        }

        return (text, nil)
    }

    private func extractFirstJSONObject(from source: String) -> (json: String, start: Int, length: Int)? {
        guard let firstBrace = source.firstIndex(of: "{") else { return nil }

        var depth = 0
        var endIndex: String.Index?
        for idx in source.indices where idx >= firstBrace {
            let ch = source[idx]
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 {
                    endIndex = source.index(after: idx)
                    break
                }
            }
        }

        guard let endIndex else { return nil }
        let json = String(source[firstBrace..<endIndex])
        let start = source.distance(from: source.startIndex, to: firstBrace)
        let length = source.distance(from: firstBrace, to: endIndex)
        return (json, start, length)
    }
}
