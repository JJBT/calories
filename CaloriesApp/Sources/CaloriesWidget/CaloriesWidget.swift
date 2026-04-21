import SwiftUI
import WidgetKit

private struct MacroWidgetEntry: TimelineEntry {
    let date: Date
    let consumedProtein: Int
    let consumedFat: Int
    let consumedCarbs: Int
    let targetProtein: Int
    let targetFat: Int
    let targetCarbs: Int
}

private struct MacroWidgetProvider: TimelineProvider {
    private let dayRolloverHour = 6

    func placeholder(in context: Context) -> MacroWidgetEntry {
        MacroWidgetEntry(
            date: .now,
            consumedProtein: 96,
            consumedFat: 44,
            consumedCarbs: 172,
            targetProtein: 158,
            targetFat: 58,
            targetCarbs: 236
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (MacroWidgetEntry) -> Void) {
        completion(MacroDataLoader().loadEntry(at: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MacroWidgetEntry>) -> Void) {
        let now = Date()
        let entry = MacroDataLoader().loadEntry(at: now)
        let calendar = Calendar.current
        let regularRefresh = calendar.date(byAdding: .minute, value: 15, to: now) ?? now.addingTimeInterval(15 * 60)
        let nextRollover = nextRolloverDate(after: now, calendar: calendar)
        let refresh = min(regularRefresh, nextRollover)
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }

    private func nextRolloverDate(after date: Date, calendar: Calendar) -> Date {
        let startOfToday = calendar.startOfDay(for: date)
        let todayRollover = calendar.date(byAdding: .hour, value: dayRolloverHour, to: startOfToday) ?? date
        if date < todayRollover {
            return todayRollover
        }

        let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? date
        return calendar.date(byAdding: .hour, value: dayRolloverHour, to: tomorrow) ?? date
    }
}

private struct MacroDataLoader {
    private let fileManager = FileManager.default
    private let dayRolloverHour = 6

    func loadEntry(at date: Date) -> MacroWidgetEntry {
        let calendar = Calendar.current
        let effectiveDate = calendar.date(byAdding: .hour, value: -dayRolloverHour, to: date) ?? date
        let dayKey = DayKey.from(effectiveDate, calendar: calendar)
        let entries = loadEntries(dayKey: dayKey)

        let consumedProtein = Int(entries.reduce(0) { $0 + $1.protein }.rounded())
        let consumedFat = Int(entries.reduce(0) { $0 + $1.fat }.rounded())
        let consumedCarbs = Int(entries.reduce(0) { $0 + $1.carbs }.rounded())

        let defaults = SharedStorage.sharedDefaults
        let targetProtein = Int(readDouble(for: SharedSettingsKey.targetProtein, from: defaults, fallback: 158).rounded())
        let targetFat = Int(readDouble(for: SharedSettingsKey.targetFat, from: defaults, fallback: 58).rounded())
        let targetCarbs = Int(readDouble(for: SharedSettingsKey.targetCarbs, from: defaults, fallback: 236).rounded())

        return MacroWidgetEntry(
            date: date,
            consumedProtein: consumedProtein,
            consumedFat: consumedFat,
            consumedCarbs: consumedCarbs,
            targetProtein: max(0, targetProtein),
            targetFat: max(0, targetFat),
            targetCarbs: max(0, targetCarbs)
        )
    }

    private func loadEntries(dayKey: String) -> [WidgetFoodEntry] {
        guard let baseDir = try? SharedStorage.foodLogDirectory(fileManager: fileManager) else { return [] }
        let url = baseDir.appendingPathComponent("\(dayKey).json")

        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([WidgetFoodEntry].self, from: data) else {
            return []
        }

        return entries
    }

    private func readDouble(for key: String, from defaults: UserDefaults, fallback: Double) -> Double {
        guard let number = defaults.object(forKey: key) as? NSNumber else { return fallback }
        return number.doubleValue
    }
}

private struct WidgetFoodEntry: Codable {
    let id: UUID
    let name: String
    let calories: Double
    let protein: Double
    let fat: Double
    let carbs: Double
    let source: String?
    let createdAt: Date
}

private struct MacrosWideWidgetView: View {
    let entry: MacroWidgetEntry

    var body: some View {
        HStack(spacing: 10) {
            MacroGaugeCard(
                title: "БЕЛКИ",
                consumed: entry.consumedProtein,
                target: entry.targetProtein,
                tint: Color(red: 0.26, green: 0.57, blue: 0.96)
            )

            MacroGaugeCard(
                title: "ЖИРЫ",
                consumed: entry.consumedFat,
                target: entry.targetFat,
                tint: Color(red: 0.97, green: 0.61, blue: 0.19)
            )

            MacroGaugeCard(
                title: "УГЛЕВОДЫ",
                consumed: entry.consumedCarbs,
                target: entry.targetCarbs,
                tint: Color(red: 0.33, green: 0.72, blue: 0.40)
            )
        }
        .padding(12)
        .containerBackground(for: .widget) {
            Color(uiColor: .systemBackground)
        }
    }
}

private struct MacroGaugeCard: View {
    let title: String
    let consumed: Int
    let target: Int
    let tint: Color

    private var progress: Double {
        guard target > 0 else { return 0 }
        return min(max(Double(consumed) / Double(target), 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(uiColor: .tertiaryLabel))
                .lineLimit(1)

            MacroSpeedometer(progress: progress, tint: tint)
                .frame(height: 46)

            Text("\(consumed) / \(target) г")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(uiColor: .label))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(uiColor: .separator).opacity(0.45), lineWidth: 0.8)
        )
    }
}

private struct MacroSpeedometer: View {
    let progress: Double
    let tint: Color

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let lineWidth = max(4, size * 0.1)
            let needleWidth = max(2, lineWidth * 0.45)
            let radius = max(0, size / 2 - lineWidth / 2)
            let angle = -90 + 180 * clampedProgress

            ZStack {
                Circle()
                    .trim(from: 0.5, to: 1)
                    .stroke(
                        Color(uiColor: .systemGray4),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )

                Circle()
                    .trim(from: 0.5, to: 0.5 + 0.5 * clampedProgress)
                    .stroke(
                        tint,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )

                Capsule()
                    .fill(tint)
                    .frame(width: needleWidth, height: radius * 0.82)
                    .offset(y: -(radius * 0.41))
                    .rotationEffect(.degrees(angle))

                Circle()
                    .fill(tint)
                    .frame(width: lineWidth, height: lineWidth)
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct CaloriesMacrosWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CaloriesMacrosWidget", provider: MacroWidgetProvider()) { entry in
            MacrosWideWidgetView(entry: entry)
        }
        .configurationDisplayName("БЖУ за сегодня")
        .description("Широкий виджет Б/Ж/У: потреблено и дневная норма.")
        .supportedFamilies([.systemMedium])
    }
}

@main
struct CaloriesWidgetBundle: WidgetBundle {
    var body: some Widget {
        CaloriesMacrosWidget()
    }
}

#Preview(as: .systemMedium) {
    CaloriesMacrosWidget()
} timeline: {
    MacroWidgetEntry(
        date: .now,
        consumedProtein: 162,
        consumedFat: 58,
        consumedCarbs: 244,
        targetProtein: 158,
        targetFat: 58,
        targetCarbs: 236
    )
}
