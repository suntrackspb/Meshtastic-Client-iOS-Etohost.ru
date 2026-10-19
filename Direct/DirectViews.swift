import SwiftUI

struct DirectListView: View {
    @Environment(DirectStore.self) private var direct
    @Environment(NodesStore.self) private var nodes
    @Environment(AppRouter.self) private var router
    @State private var showPicker = false

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.directPath) {
            List {
                ForEach(direct.conversations) { conversation in
                    NavigationLink(value: conversation.peer) {
                        ConversationRow(conversation: conversation, node: nodes.nodes[NodeID.string(conversation.peer)])
                    }
                }
                .onDelete { offsets in
                    let list = direct.conversations
                    offsets.forEach { direct.deleteConversation(list[$0].peer) }
                }
            }
            .listStyle(.plain)
            .overlay {
                if direct.conversations.isEmpty {
                    ContentUnavailableView {
                        Label("Нет личных сообщений", systemImage: "envelope")
                    } description: {
                        Text("Личка работает только через радио: в зеркало PKI-сообщения не попадают.")
                    } actions: {
                        Button("Написать ноде") { showPicker = true }
                    }
                }
            }
            .navigationTitle("Личные")
            .navigationDestination(for: UInt32.self) { ConversationView(peer: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showPicker = true } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("Новое сообщение")
                }
            }
            .sheet(isPresented: $showPicker) {
                NodePicker { peer in
                    showPicker = false
                    router.openConversation(with: peer)
                }
            }
        }
    }
}

private struct ConversationRow: View {
    let conversation: Conversation
    let node: MeshNode?

    var body: some View {
        HStack(spacing: 12) {
            NodeAvatar(nodeId: NodeID.string(conversation.peer), shortName: node?.shortName, size: 46)
                .overlay(alignment: .bottomTrailing) {
                    if let node { OnlineDot(isOnline: node.isOnline) }
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(node?.displayName ?? NodeID.string(conversation.peer))
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text(conversation.last.date, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text((conversation.last.isOutgoing ? "Вы: " : "") + conversation.last.text)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    if conversation.unread > 0 {
                        Text("\(conversation.unread)")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.tint, in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct ConversationView: View {
    let peer: UInt32
    @Environment(DirectStore.self) private var direct
    @Environment(NodesStore.self) private var nodes
    @Environment(RadioManager.self) private var radio
    @State private var replyTo: (id: Int64, preview: String)?

    private var node: MeshNode? { nodes.nodes[NodeID.string(peer)] }

    var body: some View {
        let thread = direct.thread(with: peer)
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(Array(thread.enumerated()), id: \.element.id) { index, message in
                    if thread.startsNewDay(at: index, date: \.date) {
                        DaySeparator(date: message.date)
                    }
                    DirectBubble(message: message,
                                 replyTo: message.replyTo.flatMap { r in thread.first { Int64($0.packetId) == r } })
                        .id(message.id)
                        .contextMenu {
                            if radio.isConnected {
                                Button("Ответить", systemImage: "arrowshape.turn.up.left") {
                                    replyTo = (Int64(message.packetId), message.text)
                                }
                            }
                            Button("Копировать", systemImage: "doc.on.doc") {
                                UIPasteboard.general.string = message.text
                            }
                            if let reason = message.failureReason {
                                Text("Ошибка: \(reason)")
                            }
                        }
                }
            }
            .padding()
        }
        .defaultScrollAnchor(.bottom)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Composer(placeholder: "Сообщение", isEnabled: radio.isConnected, replyTo: $replyTo) { text in
                try await radio.sendDirectMessage(text, to: peer, replyTo: replyTo?.id)
            }
        }
        .navigationTitle(node?.displayName ?? NodeID.string(peer))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(node?.displayName ?? NodeID.string(peer)).font(.headline).lineLimit(1)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            direct.openPeer = peer
            direct.markRead(peer)
        }
        .onDisappear {
            direct.openPeer = nil
            direct.markRead(peer)
        }
    }

    private var subtitle: String {
        var parts = [NodeID.string(peer)]
        if let hops = node?.hopsAway { parts.append(hops == 0 ? "напрямую" : "\(hops) хоп") }
        if let heard = node?.lastHeard { parts.append(heard.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: " · ")
    }
}

private struct DirectBubble: View {
    let message: DirectMessage
    let replyTo: DirectMessage?

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 50) }
            VStack(alignment: .leading, spacing: 4) {
                if let replyTo {
                    Text(replyTo.text)
                        .font(.caption)
                        .lineLimit(1)
                        .opacity(0.75)
                        .padding(.leading, 6)
                        .overlay(alignment: .leading) { Rectangle().frame(width: 2).opacity(0.6) }
                }
                Text(message.text).textSelection(.enabled)
                HStack(spacing: 4) {
                    Text(message.date, format: .dateTime.hour().minute())
                    if message.isOutgoing { statusIcon }
                    if let hops = message.hops, !message.isOutgoing {
                        Label("\(hops)", systemImage: "arrow.triangle.branch").labelStyle(CompactLabelStyle())
                    }
                }
                .font(.caption2)
                .opacity(0.7)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(message.isOutgoing ? .white : .primary)
            .background(message.isOutgoing ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if !message.isOutgoing { Spacer(minLength: 50) }
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch message.status {
        case .sending: Image(systemName: "clock").accessibilityLabel("Отправляется")
        case .sent: Image(systemName: "checkmark").accessibilityLabel("Отправлено")
        case .delivered: Image(systemName: "checkmark.circle.fill").accessibilityLabel("Доставлено")
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).accessibilityLabel("Не доставлено")
        case .received: EmptyView()
        }
    }
}

/// Выбор ноды для нового диалога: сначала ноды из радиоэфира.
private struct NodePicker: View {
    let onPick: (UInt32) -> Void
    @Environment(NodesStore.self) private var nodes
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        NavigationStack {
            let list = NodeFilter(lastHeard: .any).apply(to: nodes.nodes.values, search: search)
                .sorted { ($0.sources.contains(.radio) ? 0 : 1) < ($1.sources.contains(.radio) ? 0 : 1) }
                .prefix(200)
            List(Array(list)) { node in
                Button {
                    if let num = NodeID.num(node.id) { onPick(num) }
                } label: {
                    HStack(spacing: 12) {
                        NodeAvatar(nodeId: node.id, shortName: node.shortName, size: 36)
                        VStack(alignment: .leading) {
                            Text(node.displayName)
                            Text(node.id).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if node.sources.contains(.radio) {
                            Image(systemName: "dot.radiowaves.up.forward").foregroundStyle(.green)
                        }
                    }
                }
                .tint(.primary)
            }
            .listStyle(.plain)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Long/short name или !id")
            .navigationTitle("Кому написать")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
            }
        }
    }
}
