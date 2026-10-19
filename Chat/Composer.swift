import SwiftUI

/// Поле ввода внизу чата / диалога. Отправка идёт только через подключённую ноду.
struct Composer: View {
    let placeholder: String
    let isEnabled: Bool
    @Binding var replyTo: (id: Int64, preview: String)?
    let onSend: (String) async throws -> Void

    @State private var text = ""
    @State private var isSending = false
    @State private var error: String?
    @FocusState private var focused: Bool
    @AppStorage("glyphZipLevel") private var zipLevel = 0

    /// Что реально уйдёт в эфир.
    private var outgoing: String { GlyphZip.apply(text, level: zipLevel) }

    /// Лимит полезной нагрузки текстового пакета Meshtastic.
    private let maxBytes = 200

    var body: some View {
        VStack(spacing: 6) {
            if let replyTo {
                HStack {
                    Image(systemName: "arrowshape.turn.up.left").foregroundStyle(.tint)
                    Text(replyTo.preview).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                    Spacer()
                    Button { self.replyTo = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Отменить ответ")
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(isEnabled ? placeholder : "Подключите ноду, чтобы писать", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .disabled(!isEnabled)

                let bytes = outgoing.utf8.count
                Button {
                    zipLevel = (zipLevel + 1) % (GlyphZip.levels.upperBound + 1)
                } label: {
                    let tint = GlyphZip.color(zipLevel)
                    Text("ZIP")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .frame(height: 32)
                        .foregroundStyle(tint)
                        .background(tint.opacity(0.18), in: Capsule())
                        .overlay(Capsule().strokeBorder(tint.opacity(0.6), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(GlyphZip.hint(zipLevel))

                Button(action: send) {
                    if isSending {
                        ProgressView().frame(width: 32, height: 32)
                    } else {
                        // resizable + рамка: у символа со шрифтом есть подстрочный отступ,
                        // из-за которого при выравнивании по низу кнопка «всплывала» на пару точек.
                        Image(systemName: "arrow.up.circle.fill")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 32, height: 32)
                            .foregroundStyle(canSend ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    }
                }
                // На Mac (Catalyst) стиль по умолчанию — серая плашка вокруг иконки.
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
                .accessibilityLabel("Отправить")
            }
            if !text.isEmpty {
                byteCounter
            }
        }
        .padding(.horizontal)
        // Как в Сообщениях: смахнуть поле ввода вниз — клавиатура прячется.
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 12).onEnded { value in
                if value.translation.height > 20, abs(value.translation.height) > abs(value.translation.width) {
                    focused = false
                }
            }
        )
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Счётчик байт как в AppMeshastic: остаток, сэкономлено, полоска заполнения.
    private var byteCounter: some View {
        let bytes = outgoing.utf8.count
        let saved = text.utf8.count - bytes
        let ratio = Double(bytes) / Double(maxBytes)
        let color: Color = ratio >= 1 ? .red : ratio >= 0.85 ? .orange : ratio >= 0.65 ? .yellow : .secondary
        return HStack(spacing: 8) {
            Text(bytes > maxBytes ? "Превышено на \(bytes - maxBytes) байт" : "Осталось \(maxBytes - bytes) байт")
                .foregroundStyle(color)
            if zipLevel > 0, saved > 0 {
                Text("−\(saved) байт").foregroundStyle(.green)
            }
            ProgressView(value: min(ratio, 1))
                .tint(color == .secondary ? .accentColor : color)
        }
        .font(.caption2.monospacedDigit())
    }

    private var canSend: Bool {
        isEnabled && !isSending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && outgoing.utf8.count <= maxBytes
    }

    private func send() {
        let message = outgoing.trimmingCharacters(in: .whitespacesAndNewlines)
        isSending = true
        error = nil
        Task {
            do {
                try await onSend(message)
                text = ""
                replyTo = nil
            } catch {
                self.error = error.localizedDescription
            }
            isSending = false
        }
    }
}
