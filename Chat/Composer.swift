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

                let bytes = text.utf8.count
                Button(action: send) {
                    if isSending {
                        ProgressView().frame(width: 32, height: 32)
                    } else {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                    }
                }
                .disabled(!isEnabled || isSending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || bytes > maxBytes)
                .accessibilityLabel("Отправить")
            }
            if text.utf8.count > maxBytes * 3 / 4 {
                Text("\(text.utf8.count)/\(maxBytes) байт")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(text.utf8.count > maxBytes ? .red : .secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
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

    private func send() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
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
