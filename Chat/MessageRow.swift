import SwiftUI

struct MessageRow: View {
    let message: ChatMessage
    let replyTo: ChatMessage?
    /// Сообщение с моей ноды (в т.ч. отправленное с другого клиента и пришедшее из зеркала).
    var isMine = false
    var reactions: [ChatStore.ReactionGroup] = []
    var onShowRelays: (Int) -> Void = { _ in }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isMine {
                Spacer(minLength: 50)
            } else {
                NodeAvatar(nodeId: message.fromId, shortName: message.senderShort, size: 36)
            }

            VStack(alignment: .leading, spacing: 4) {
                if !isMine {
                    HStack(spacing: 6) {
                        Text(message.senderLong ?? message.fromId)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if message.isBot {
                            Image(systemName: "cpu").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Text(message.date, format: .dateTime.hour().minute())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if let replyTo {
                    HStack(spacing: 6) {
                        Rectangle().fill(isMine ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.secondary)).frame(width: 2)
                        Text("\(replyTo.senderShort ?? replyTo.fromId): \(replyTo.text)")
                            .font(.caption)
                            .foregroundStyle(isMine ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }

                Text(message.text)
                    .font(.body)
                    .textSelection(.enabled)

                if !reactions.isEmpty {
                    ReactionChips(reactions: reactions, onTint: isMine)
                        .padding(.vertical, 2)
                }

                HStack(spacing: 10) {
                    if isMine {
                        // Для своих сообщений источник не важен, только время и шлюзы.
                        Text(message.date, format: .dateTime.hour().minute())
                    } else if message.sources.contains(.radio) {
                        // Радио-сообщение и так окажется в зеркале — второй бейдж не нужен.
                        Label("RX", systemImage: "dot.radiowaves.up.forward")
                        if let hops = message.hops {
                            Label("\(hops)", systemImage: "arrow.triangle.branch")
                        }
                    } else {
                        Label("MQTT", systemImage: "globe")
                    }
                    if message.relayCount > 0, let mirrorId = message.mirrorId {
                        Button {
                            onShowRelays(mirrorId)
                        } label: {
                            Label("\(message.relayCount)", systemImage: "antenna.radiowaves.left.and.right")
                                .lineLimit(1)
                                .fixedSize()
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(isMine ? AnyShapeStyle(.white.opacity(0.2)) : AnyShapeStyle(.fill.tertiary), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Шлюзы: \(message.relayCount). Показать на карте")
                    }
                }
                .font(.caption2)
                .foregroundStyle(isMine ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                .labelStyle(CompactLabelStyle())
                .frame(maxWidth: isMine ? .infinity : nil, alignment: .trailing)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .foregroundStyle(isMine ? .white : .primary)
            .background(isMine ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.quaternary),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
    }
}

private struct ReactionChips: View {
    let reactions: [ChatStore.ReactionGroup]
    /// Пузырь своего сообщения залит акцентным цветом — подложка нужна полупрозрачная белая.
    var onTint = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(reactions) { group in
                ReactionChip(group: group, onTint: onTint)
            }
        }
        .fixedSize()
    }
}

/// Значок реакции; по нажатию — поповер со списком поставивших.
private struct ReactionChip: View {
    let group: ChatStore.ReactionGroup
    let onTint: Bool
    @State private var showSenders = false

    var body: some View {
        Button {
            showSenders = true
        } label: {
            HStack(spacing: 3) {
                Text(group.emoji)
                if group.senders.count > 1 {
                    Text("\(group.senders.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(onTint ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                }
            }
            .font(.footnote)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(onTint ? AnyShapeStyle(.white.opacity(0.2)) : AnyShapeStyle(.fill.tertiary), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.emoji): \(group.senders.map { $0.longName ?? $0.nodeId }.joined(separator: ", "))")
        .accessibilityHint("Показать, кто поставил")
        .popover(isPresented: $showSenders) {
            VStack(alignment: .leading, spacing: 10) {
                Text(group.emoji).font(.title2)
                ForEach(group.senders) { sender in
                    HStack(spacing: 10) {
                        NodeAvatar(nodeId: sender.nodeId, shortName: sender.shortName, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(sender.longName ?? sender.nodeId).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text(sender.date, format: .dateTime.hour().minute())
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding()
            .frame(minWidth: 200, alignment: .leading)
            .presentationCompactAdaptation(.popover)
        }
    }
}

struct NodeAvatar: View {
    let nodeId: String
    let shortName: String?
    var size: CGFloat = 40

    var body: some View {
        let color = Color.node(nodeId)
        Text(shortName ?? "?")
            .font(.system(size: size * 0.32, weight: .bold))
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .foregroundStyle(color.contrastingText)
            .frame(width: size, height: size)
            .background(color, in: Circle())
            .accessibilityHidden(true)
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}
