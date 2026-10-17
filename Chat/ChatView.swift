import SwiftUI

struct ChatView: View {
    @Environment(ChatStore.self) private var chat
    @Environment(MirrorRealtime.self) private var mirror
    @Environment(RadioManager.self) private var radio
    @State private var selected: MeshChannel?
    @State private var relayMap: RelayMapTarget?
    @State private var replyTo: (id: Int64, preview: String)?
    /// Вкладка «Чат» на экране (TabView держит view живой и на других вкладках).
    @State private var isVisible = false

    /// Каналы ноды; пока ноды не было — все каналы зеркала.
    private var channels: [MeshChannel] { chat.visibleChannels }

    /// Выбранный канал, если он ещё есть в списке, иначе первый.
    private var channel: MeshChannel {
        selected.flatMap { s in channels.first { $0 == s } } ?? channels[0]
    }

    static let quickReactions = ["👍", "❤️", "😂", "🔥", "💯", "👀"]

    private func react(_ emoji: String, to packetId: Int64, in channel: RadioManager.RadioChannel) {
        Task { try? await radio.sendChannelMessage(emoji, channel: channel, replyTo: packetId, isEmoji: true) }
    }

    private var radioChannel: RadioManager.RadioChannel? {
        radio.channels.first { $0.name.lowercased() == channel.id }
    }

    var body: some View {
        NavigationStack {
            let channel = self.channel
            let items = chat.messages(in: channel)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if !items.isEmpty {
                            Button {
                                Task { await chat.loadOlderFromMirror() }
                            } label: {
                                if chat.isLoadingHistory { ProgressView() } else { Text("Загрузить раньше") }
                            }
                            .font(.footnote)
                            .padding(.vertical, 4)
                        }
                        ForEach(items) { message in
                            MessageRow(message: message,
                                       replyTo: message.replyToPacketId.flatMap(chat.message(packetId:)),
                                       isMine: message.isOutgoing || message.fromId == radio.myNodeId ?? UserDefaults.myNodeId,
                                       reactions: message.packetId.map(chat.reactions(to:)) ?? [],
                                       onShowRelays: { relayMap = RelayMapTarget(id: $0) })
                                .id(message.id)
                                .contextMenu {
                                    if let packetId = message.packetId, radio.isConnected, let radioChannel {
                                        ControlGroup {
                                            ForEach(Self.quickReactions, id: \.self) { emoji in
                                                Button(emoji) { react(emoji, to: packetId, in: radioChannel) }
                                            }
                                        }
                                        .controlGroupStyle(.compactMenu)
                                        Button("Ответить", systemImage: "arrowshape.turn.up.left") {
                                            replyTo = (packetId, "\(message.senderShort ?? message.fromId): \(message.text)")
                                        }
                                    }
                                    Button("Копировать", systemImage: "doc.on.doc") {
                                        UIPasteboard.general.string = message.text
                                    }
                                }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .defaultScrollAnchor(.bottom)
                .overlay {
                    if items.isEmpty {
                        ContentUnavailableView("Нет сообщений", systemImage: "bubble.left",
                                               description: Text("В канале \(channel.name) пока тихо"))
                    }
                }
                .onChange(of: items.last?.id) { _, last in
                    guard let last else { return }
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                    // Пришло сообщение в открытый канал — оно сразу прочитано.
                    if isVisible { chat.markRead(channel) }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                ChannelTabs(channels: channels,
                            selection: Binding(get: { channel }, set: { selected = $0 }),
                            unread: { chat.unreadCount(in: $0, myNodeId: radio.myNodeId ?? UserDefaults.myNodeId) })
            }
            .onAppear {
                isVisible = true
                chat.markRead(channel)
            }
            .onDisappear {
                chat.markRead(channel)
                isVisible = false
            }
            .onChange(of: channel) { old, new in
                chat.markRead(old)
                chat.markRead(new)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Composer(placeholder: "Сообщение в \(channel.name)",
                         isEnabled: radio.isConnected && radioChannel != nil,
                         replyTo: $replyTo) { text in
                    guard let radioChannel else { return }
                    try await radio.sendChannelMessage(text, channel: radioChannel, replyTo: replyTo?.id)
                }
            }
            .sheet(item: $relayMap) { RelayMapSheet(mirrorId: $0.id) }
            .navigationTitle(channel.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Image(systemName: "dot.radiowaves.up.forward")
                        .foregroundStyle(radio.isConnected ? .green : .secondary)
                        .accessibilityLabel(radio.isConnected ? "Нода подключена" : "Нода не подключена")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    MirrorStatusBadge(state: mirror.state) { mirror.reconnectNow() }
                }
            }
        }
    }
}

private struct ChannelTabs: View {
    let channels: [MeshChannel]
    @Binding var selection: MeshChannel
    let unread: (MeshChannel) -> Int

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(channels) { ch in
                    let selected = ch == selection
                    let count = selected ? 0 : unread(ch)
                    Button {
                        selection = ch
                    } label: {
                        HStack(spacing: 6) {
                            Text(ch.name)
                            if count > 0 {
                                Text(count > 99 ? "99+" : "\(count)")
                                    .font(.caption2.weight(.bold).monospacedDigit())
                                    .foregroundStyle(ch.color.contrastingText)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(ch.color, in: Capsule())
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .foregroundStyle(selected ? ch.color.contrastingText : .primary)
                        .background(selected ? AnyShapeStyle(ch.color) : AnyShapeStyle(.fill.tertiary), in: Capsule())
                        .animation(.snappy, value: count)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityValue(count > 0 ? "\(count) непрочитанных" : "")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }
}

struct MirrorStatusBadge: View {
    let state: MirrorRealtime.State
    let onRetry: () -> Void

    var body: some View {
        Button(action: onRetry) {
            HStack(spacing: 4) {
                Image(systemName: "globe")
                switch state {
                case .connected: Circle().fill(.green).frame(width: 7, height: 7)
                case .connecting: ProgressView().controlSize(.mini)
                case .waiting(let s): Text("\(s)с").font(.caption2.monospacedDigit())
                case .offline, .idle: Circle().fill(.red).frame(width: 7, height: 7)
                }
            }
        }
        .accessibilityLabel(label)
    }

    private var label: String {
        switch state {
        case .connected: "Зеркало подключено"
        case .connecting: "Подключение к зеркалу"
        case .waiting(let s): "Повтор через \(s) секунд"
        case .offline: "Нет сети"
        case .idle: "Зеркало отключено"
        }
    }
}
