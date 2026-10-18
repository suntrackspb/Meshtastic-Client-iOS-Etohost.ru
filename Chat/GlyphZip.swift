import SwiftUI

/// GlyphZip: кириллица в UTF-8 — 2 байта на букву, латиница — 1. Похожие буквы меняем
/// на латинские, чтобы в лимит пакета влезало больше текста.
/// Таблицы — из github.com/5CORNERS/GlyphZip (как в AppMeshastic).
enum GlyphZip {
    /// 1 — безопасные замены, 2 — плюс похожие символы, 3 — максимальное сжатие.
    static let levels = 0...3

    private static let group1: [Character: Character] = [
        "А": "A", "В": "B", "Е": "E", "К": "K", "М": "M", "Н": "H", "О": "O", "Р": "P", "С": "C", "Т": "T", "Х": "X",
        "а": "a", "е": "e", "ё": "e", "о": "o", "р": "p", "с": "c", "у": "y", "х": "x", "—": "-",
    ]
    private static let group2: [Character: Character] = ["т": "m", "п": "n", "и": "u", "д": "g"]
    private static let group3: [Character: Character] = [
        "б": "6", "З": "3", "У": "Y", "Д": "D", "к": "k", "г": "r", "т": "t", "ш": "w", "Ш": "W", "ч": "4", "ь": "b",
    ]

    static func apply(_ text: String, level: Int) -> String {
        guard level > 0 else { return text }
        return String(text.map { ch in
            if level >= 2, let r = group2[ch] { return r }
            if level >= 3, let r = group3[ch] { return r }
            if let r = group1[ch] { return r }
            return ch
        })
    }

    /// Уровень показываем цветом: серый — выкл, зелёный, жёлтый, красный.
    static func color(_ level: Int) -> Color { [.gray, .green, .yellow, .red][level] }

    static func hint(_ level: Int) -> String {
        ["GlyphZip выключен", "Уровень 1: безопасные замены", "Уровень 2: + похожие символы", "Уровень 3: максимальное сжатие"][level]
    }
}
