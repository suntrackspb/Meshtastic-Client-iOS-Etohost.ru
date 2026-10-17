import SwiftUI

/// Каналы, которые есть в зеркале (frontend/src/config/channels.config.json).
struct MeshChannel: Identifiable, Hashable {
    let name: String
    let label: String
    let color: Color
    let isModemPreset: Bool

    var id: String { name.lowercased() }

    static let mirrorChannels: [MeshChannel] = [
        MeshChannel(name: "MediumFast", label: "MF", color: Color(hex: 0x58A6FF), isModemPreset: true),
        MeshChannel(name: "LongFast", label: "LF", color: Color(hex: 0x3FB950), isModemPreset: true),
        MeshChannel(name: "Services", label: "SV", color: Color(hex: 0xD2991A), isModemPreset: false),
        MeshChannel(name: "Anime", label: "AN", color: Color(hex: 0xC084FC), isModemPreset: false),
    ]

    /// Канал по имени без учёта регистра; неизвестный канал (только из ноды) получает серый цвет.
    static func named(_ name: String) -> MeshChannel {
        mirrorChannels.first { $0.id == name.lowercased() }
            ?? MeshChannel(name: name, label: String(name.prefix(2)).uppercased(), color: .gray, isModemPreset: false)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// Стабильный цвет аватара ноды, как в официальном клиенте: из num ноды.
    static func node(_ nodeId: String) -> Color {
        let num = UInt32(nodeId.trimmingCharacters(in: CharacterSet(charactersIn: "!")), radix: 16) ?? 0
        return Color(hex: num & 0xFFFFFF)
    }
}

extension Color {
    /// Читаемый цвет текста поверх `self`.
    var contrastingText: Color {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: nil)
        return (0.299 * r + 0.587 * g + 0.114 * b) > 0.6 ? .black : .white
    }
}
