import SwiftUI
import UIKit

/// Частота использования реакций: в быстром наборе — самые используемые.
enum ReactionUsage {
    private static let key = "reactionUsage"
    static let defaults = ["👍", "❤️", "😂", "🔥", "👀"]

    private static var counts: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func record(_ emoji: String) { counts[emoji, default: 0] += 1 }

    /// Топ `limit`: сначала использованные (по частоте), добивается стандартными.
    static func top(_ limit: Int = 5) -> [String] {
        let used = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
        var result: [String] = []
        for e in used + defaults where !result.contains(e) {
            result.append(e)
            if result.count == limit { break }
        }
        return result
    }
}

/// Цель выбора произвольной реакции.
struct ReactionTarget: Identifiable {
    let packetId: Int64
    var id: Int64 { packetId }
}

/// Шторка выбора любого эмодзи: системная эмодзи-клавиатура + сетка частых.
struct EmojiPickerSheet: View {
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private static let common = ["👍", "👎", "❤️", "😂", "🔥", "💯", "👀", "🙏", "👏", "🎉",
                                 "😮", "😢", "😡", "🤔", "😎", "🤝", "✅", "❌", "⚡️", "📡",
                                 "🛰️", "📶", "🔋", "🏔️", "🌧️", "☀️", "🌙", "🍺", "☕️", "🚀"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    EmojiField { pick($0) }
                        .frame(height: 44)
                        .padding(.horizontal, 12)
                        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Text("Введите любой эмодзи с клавиатуры или выберите ниже")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(Self.common, id: \.self) { emoji in
                            Button { pick(emoji) } label: {
                                Text(emoji).font(.system(size: 32))
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Реакция")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func pick(_ emoji: String) {
        onPick(emoji)
        dismiss()
    }
}

/// Поле, сразу открывающее эмодзи-клавиатуру; отдаёт первый введённый эмодзи.
private struct EmojiField: UIViewRepresentable {
    let onEmoji: (String) -> Void

    func makeUIView(context: Context) -> EmojiTextField {
        let field = EmojiTextField()
        field.placeholder = "😀 Любой эмодзи"
        field.font = .systemFont(ofSize: 24)
        field.delegate = context.coordinator
        DispatchQueue.main.async { field.becomeFirstResponder() }
        return field
    }

    func updateUIView(_ uiView: EmojiTextField, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onEmoji: onEmoji) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        let onEmoji: (String) -> Void
        init(onEmoji: @escaping (String) -> Void) { self.onEmoji = onEmoji }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange,
                       replacementString string: String) -> Bool {
            if let ch = string.first, ch.unicodeScalars.contains(where: { $0.properties.isEmoji && $0.value > 0xFF }) {
                onEmoji(String(ch))
            }
            return false
        }
    }
}

final class EmojiTextField: UITextField {
    override var textInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" } ?? super.textInputMode
    }
}
