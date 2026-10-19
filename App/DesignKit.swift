import SwiftUI

// Общие визуальные элементы. Только отображение — логику не трогают.

extension MeshNode {
    /// Онлайн, как в официальном клиенте: слышна за последние 2 часа.
    var isOnline: Bool {
        guard let lastHeard else { return false }
        return Date.now.timeIntervalSince(lastHeard) < 7200
    }
}

/// Точка «онлайн» поверх аватара.
struct OnlineDot: View {
    let isOnline: Bool
    var size: CGFloat = 12

    var body: some View {
        Circle()
            .fill(isOnline ? Color.green : Color.gray.opacity(0.6))
            .frame(width: size, height: size)
            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
            .accessibilityLabel(isOnline ? "Онлайн" : "Не в сети")
    }
}

/// Иконка батареи по уровню, с цветом. Уровень > 100 — питание от сети.
struct BatteryBadge: View {
    let level: Int

    var body: some View {
        Label(level > 100 ? "Сеть" : "\(level)%", systemImage: symbol)
            .foregroundStyle(color)
            .accessibilityLabel(level > 100 ? "Питание от сети" : "Батарея \(level)%")
    }

    private var symbol: String {
        switch level {
        case 101...: "powerplug.fill"
        case 76...100: "battery.100percent"
        case 51...75: "battery.75percent"
        case 26...50: "battery.50percent"
        case 11...25: "battery.25percent"
        default: "battery.0percent"
        }
    }

    private var color: Color {
        switch level {
        case 101...: .blue
        case 26...100: .secondary
        case 11...25: .orange
        default: .red
        }
    }
}

/// Качество сигнала по SNR (пороги близки к официальному клиенту для LongFast).
struct SNRBadge: View {
    let snr: Double

    var body: some View {
        Label {
            Text(String(format: "%.1f дБ", snr))
        } icon: {
            Image(systemName: "cellularbars", variableValue: quality)
        }
            .foregroundStyle(color)
            .accessibilityLabel(String(format: "SNR %.1f дБ", snr))
    }

    private var quality: Double {
        switch snr {
        case 0...: 1
        case -7.5..<0: 0.66
        case -15 ..< -7.5: 0.33
        default: 0.1
        }
    }

    private var color: Color {
        switch snr {
        case 0...: .green
        case -7.5..<0: .yellow
        case -15 ..< -7.5: .orange
        default: .red
        }
    }
}

/// Плитка статистики: число + подпись.
struct StatTile: View {
    let value: String
    let title: LocalizedStringKey
    let systemImage: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(minWidth: 76, alignment: .leading)
        .padding(10)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Разделитель дня в ленте сообщений.
struct DaySeparator: View {
    let date: Date

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.fill.tertiary, in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private var title: String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return String(localized: "Сегодня") }
        if cal.isDateInYesterday(date) { return String(localized: "Вчера") }
        if cal.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        }
        return date.formatted(.dateTime.day().month(.wide).year())
    }
}

extension Array {
    /// Нужен ли разделитель дня перед элементом с индексом `index`.
    func startsNewDay(at index: Int, date: (Element) -> Date) -> Bool {
        guard index > 0 else { return true }
        return !Calendar.current.isDate(date(self[index - 1]), inSameDayAs: date(self[index]))
    }
}
