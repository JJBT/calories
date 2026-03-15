import Foundation
import UIKit

/// Хранит историю чата на день. Обнуляется при смене дня.
///
/// Требования:
/// - UI должен показывать историю "за сегодня" при открытии чата
/// - В контекст модели отправляем последние N сообщений
final class ChatHistoryStore {
    private let retentionDays = 3

    struct PersistedMessage: Codable {
        var id: UUID
        var role: ChatMessage.Role
        var text: String
        var createdAt: Date
        var imageFilenames: [String]
    }

    private let fileManager: FileManager
    private let calendar: Calendar

    init(fileManager: FileManager = .default, calendar: Calendar = .current) {
        self.fileManager = fileManager
        self.calendar = calendar
    }

    /// Ключ дня для хранения истории.
    ///
    /// День "переключается" не в полночь, а в час `resetHour`.
    /// По умолчанию resetHour = 4 (04:00), но можно переопределить через env.
    /// Ключ дня для хранения истории.
    ///
    /// День "переключается" не в полночь, а в час `resetHour`.
    /// По умолчанию resetHour = 4 (04:00), но можно переопределить через env.
    ///
    /// - date: какой день выбрал пользователь (в UI)
    /// - now: текущее время (нужно только чтобы понять "какой сегодня день" при resetHour)
    func dayKey(for date: Date, now: Date = .now) -> String {
        let resetHour = chatResetHour()

        // Логика такая:
        // - До resetHour считаем, что "сейчас" ещё относится к предыдущему дню.
        // - Поэтому выбранный day "сегодня" в UI должен соответствовать effectiveToday.
        // Здесь ключ всегда формируем просто по components выбранной даты.
        // А корректное значение selectedDay (today vs yesterday) должно задаваться выше (в UI/state).
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        let y = comps.year ?? 0
        let m = comps.month ?? 0
        let d = comps.day ?? 0
        _ = now // keep signature for future tweaks
        _ = resetHour
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    /// "Сегодня" с учётом часа resetHour (по умолчанию 4 утра).
    func effectiveToday(now: Date = .now) -> Date {
        let resetHour = chatResetHour()
        let hour = calendar.component(.hour, from: now)
        let effectiveNow = (hour < resetHour) ? (calendar.date(byAdding: .day, value: -1, to: now) ?? now) : now
        return calendar.startOfDay(for: effectiveNow)
    }

    func todayKey(now: Date = .now) -> String {
        dayKey(for: effectiveToday(now: now), now: now)
    }

    /// Час (0-23), когда чат "обнуляется" и начинается новый день.
    /// Env: CALORIES_CHAT_RESET_HOUR, по умолчанию 4.
    private func chatResetHour() -> Int {
        let env = ProcessInfo.processInfo.environment["CALORIES_CHAT_RESET_HOUR"]
        if let env, let v = Int(env.trimmingCharacters(in: .whitespacesAndNewlines)), (0...23).contains(v) {
            return v
        }
        return 4
    }

    func load(dayKey: String) -> [ChatMessage] {
        pruneOldData()
        do {
            let url = try messagesURL(dayKey: dayKey)
            guard fileManager.fileExists(atPath: url.path) else { return [] }
            let data = try Data(contentsOf: url)
            let items = try JSONDecoder().decode([PersistedMessage].self, from: data)
            return items.map { item in
                let images: [UIImage] = item.imageFilenames.compactMap { fn -> UIImage? in
                    let imgURL = imagesDirURL(dayKey: dayKey).appendingPathComponent(fn)
                    guard let data = try? Data(contentsOf: imgURL), let img = UIImage(data: data) else { return nil }
                    return img
                }
                return ChatMessage(id: item.id, role: item.role, text: item.text, images: images, createdAt: item.createdAt, isPending: false)
            }
        } catch {
            return []
        }
    }

    func save(messages: [ChatMessage], dayKey: String) {
        do {
            let url = try messagesURL(dayKey: dayKey)
            let dir = url.deletingLastPathComponent()
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: imagesDirURL(dayKey: dayKey), withIntermediateDirectories: true)

            // Сохраняем только не-pending, без system.
            let toPersist = messages
                .filter { !$0.isPending }
                .filter { $0.role != .system }

            var persisted: [PersistedMessage] = []
            persisted.reserveCapacity(toPersist.count)

            for msg in toPersist {
                var imageFilenames: [String] = []
                if !msg.images.isEmpty {
                    for img in msg.images {
                        guard let jpeg = img.jpegData(compressionQuality: 0.85) else { continue }
                        let fn = "\(UUID().uuidString).jpg"
                        let imgURL = imagesDirURL(dayKey: dayKey).appendingPathComponent(fn)
                        try? jpeg.write(to: imgURL, options: [.atomic])
                        imageFilenames.append(fn)
                    }
                }
                persisted.append(PersistedMessage(id: msg.id, role: msg.role, text: msg.text, createdAt: msg.createdAt, imageFilenames: imageFilenames))
            }

            let data = try JSONEncoder().encode(persisted)
            try data.write(to: url, options: [.atomic])
            pruneOldData()
        } catch {
            // no-op
        }
    }

    func loadDraft(dayKey: String) -> (text: String, images: [UIImage]) {
        guard let url = try? draftURL(dayKey: dayKey),
              fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return ("", [])
        }

        // backward compatibility: old format was plain text in *.txt
        if let text = String(data: data, encoding: .utf8),
           (try? JSONDecoder().decode(PersistedDraft.self, from: data)) == nil {
            return (text, [])
        }

        guard let draft = try? JSONDecoder().decode(PersistedDraft.self, from: data) else {
            return ("", [])
        }

        let images: [UIImage] = draft.imageFilenames.compactMap { fn in
            let imgURL = imagesDirURL(dayKey: dayKey).appendingPathComponent(fn)
            guard let data = try? Data(contentsOf: imgURL), let img = UIImage(data: data) else { return nil }
            return img
        }

        return (draft.text, images)
    }

    func saveDraft(text: String, images: [UIImage], dayKey: String) {
        do {
            let url = try draftURL(dayKey: dayKey)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: imagesDirURL(dayKey: dayKey), withIntermediateDirectories: true)

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let shouldClear = trimmed.isEmpty && images.isEmpty

            // delete previous draft images on each rewrite to avoid orphan files
            if fileManager.fileExists(atPath: url.path),
               let oldData = try? Data(contentsOf: url),
               let oldDraft = try? JSONDecoder().decode(PersistedDraft.self, from: oldData) {
                for fn in oldDraft.imageFilenames {
                    let oldImageURL = imagesDirURL(dayKey: dayKey).appendingPathComponent(fn)
                    try? fileManager.removeItem(at: oldImageURL)
                }
            }

            if shouldClear {
                if fileManager.fileExists(atPath: url.path) {
                    try? fileManager.removeItem(at: url)
                }
                return
            }

            var imageFilenames: [String] = []
            imageFilenames.reserveCapacity(images.count)
            for img in images {
                guard let jpeg = img.jpegData(compressionQuality: 0.85) else { continue }
                let fn = "draft-\(UUID().uuidString).jpg"
                let imgURL = imagesDirURL(dayKey: dayKey).appendingPathComponent(fn)
                try? jpeg.write(to: imgURL, options: [.atomic])
                imageFilenames.append(fn)
            }

            let draft = PersistedDraft(text: text, imageFilenames: imageFilenames)
            let payload = try JSONEncoder().encode(draft)
            try payload.write(to: url, options: [.atomic])
        } catch {
            // no-op
        }
    }

    // MARK: - Paths

    private func baseDirURL() throws -> URL {
        let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appendingPathComponent("Calories", isDirectory: true).appendingPathComponent("chat", isDirectory: true)
    }

    private func messagesURL(dayKey: String) throws -> URL {
        try baseDirURL().appendingPathComponent("\(dayKey).json")
    }

    private func draftURL(dayKey: String) throws -> URL {
        try baseDirURL().appendingPathComponent("\(dayKey)-draft.json")
    }

    private struct PersistedDraft: Codable {
        var text: String
        var imageFilenames: [String]
    }

    private func imagesDirURL(dayKey: String) -> URL {
        let support = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? fileManager.temporaryDirectory
        return support
            .appendingPathComponent("Calories", isDirectory: true)
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent(dayKey, isDirectory: true)
    }

    private func pruneOldData(now: Date = .now) {
        guard let base = try? baseDirURL() else { return }
        let cutoff = calendar.startOfDay(for: now).addingTimeInterval(TimeInterval(-(retentionDays - 1) * 86_400))

        if let files = try? fileManager.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) {
            for file in files {
                let name = file.deletingPathExtension().lastPathComponent
                let key: String
                if file.pathExtension == "json", !name.hasSuffix("-draft") {
                    key = name
                } else if (file.pathExtension == "json" || file.pathExtension == "txt"), name.hasSuffix("-draft") {
                    key = String(name.dropLast("-draft".count))
                } else {
                    continue
                }

                let parts = key.split(separator: "-")
                guard parts.count == 3,
                      let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
                      let date = calendar.date(from: DateComponents(year: y, month: m, day: d)) else { continue }

                if date < cutoff {
                    try? fileManager.removeItem(at: file)
                    if file.pathExtension == "json" {
                        let imgDir = imagesDirURL(dayKey: key)
                        try? fileManager.removeItem(at: imgDir)
                    }
                }
            }
        }
    }
}
