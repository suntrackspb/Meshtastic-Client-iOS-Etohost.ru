import Foundation
import Observation

enum MessageSource: String, Hashable, Codable {
    case radio
    case mirror
}

struct ChatMessage: Identifiable, Codable {
    /// `fromId + packetId` — одинаков для копии из радио и из зеркала, по нему и склеиваем.
    let id: String
    let packetId: Int64?
    let fromId: String
    var senderShort: String?
    var senderLong: String?
    let text: String
    let channel: String
    let date: Date
    let replyToPacketId: Int64?
    var sources: Set<MessageSource>
    var mirrorId: Int?
    /// Только для радио: хопы до нашей ноды. Хопы до MQTT-шлюза не показываем.
    var hops: Int?
    var snr: Double?
    var relayCount: Int
    var isBot: Bool
    var isOutgoing = false
    /// Tapback: эмодзи-ответ на другое сообщение.
    var isReaction = false

    static func key(fromId: String, packetId: Int64?, fallback: String) -> String {
        packetId.map { "\(fromId)#\($0)" } ?? fallback
    }
}

@MainActor
@Observable
final class ChatStore {
    private(set) var messages: [String: ChatMessage] = [:] {
        didSet {
            cachedIndex = nil
            scheduleSave()
        }
    }

    /// Производные индексы ленты. Без них каждая строка чата делала полный проход
    /// по всем сообщениям (ответ, реакции), и прокрутка становилась O(n²).
    private struct Index {
        var byChannel: [String: [ChatMessage]] = [:]
        var byPacketId: [Int64: ChatMessage] = [:]
        var reactions: [Int64: [ChatMessage]] = [:]
    }
    @ObservationIgnored private var cachedIndex: Index?

    private var index: Index {
        _ = messages // регистрируем зависимость для Observation
        if let cachedIndex { return cachedIndex }
        var idx = Index()
        let sorted = messages.values.sorted { $0.date < $1.date }
        for m in sorted {
            if let p = m.packetId, idx.byPacketId[p] == nil { idx.byPacketId[p] = m }
            if m.isReaction, let target = m.replyToPacketId { idx.reactions[target, default: []].append(m) }
        }
        for m in sorted {
            // Реакции на загруженные сообщения не показываются отдельно.
            if m.isReaction, let target = m.replyToPacketId, idx.byPacketId[target] != nil { continue }
            idx.byChannel[m.channel.lowercased(), default: []].append(m)
        }
        cachedIndex = idx
        return idx
    }
    private(set) var isLoadingHistory = false
    private var mirrorIdToKey: [Int: String] = [:]
    /// Когда канал последний раз был открыт на экране (ключ — `MeshChannel.id`).
    private var lastRead: [String: Date] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Сколько храним ленту на устройстве.
    private static let retention: TimeInterval = 14 * 24 * 3600

    private static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "chat-messages.json")
    }

    private struct Snapshot: Codable {
        var messages: [ChatMessage]
        var lastRead: [String: Date]
    }

    init() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        let cutoff = Date.now.addingTimeInterval(-Self.retention)
        var loaded: [String: ChatMessage] = [:]
        for m in snapshot.messages where m.date > cutoff {
            loaded[m.id] = m
            if let mirrorId = m.mirrorId { mirrorIdToKey[mirrorId] = m.id }
        }
        messages = loaded
        lastRead = snapshot.lastRead
    }

    /// Сброс приложения: всё забыть и удалить файл ленты.
    func reset() {
        clearMessages()
        radioChannelNames = []
    }

    /// Очистить ленту (каналы остаются).
    func clearMessages() {
        saveTask?.cancel()
        saveTask = nil
        messages = [:]
        mirrorIdToKey = [:]
        lastRead = [:]
        try? FileManager.default.removeItem(at: Self.fileURL)
    }

    /// Сохраняем не чаще раза в 2 секунды: в активном эфире сообщения и шлюзы идут пачками.
    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            self.saveTask = nil
            let snapshot = Snapshot(messages: Array(self.messages.values), lastRead: self.lastRead)
            let url = Self.fileURL
            await Task.detached(priority: .utility) {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
            }.value
        }
    }

    // MARK: - Непрочитанное

    /// Непрочитанные в канале: чужие сообщения (не реакции) новее момента последнего просмотра.
    /// Канал, который ещё ни разу не открывали, считается прочитанным до текущего запуска.
    func unreadCount(in channel: MeshChannel, myNodeId: String?) -> Int {
        let since = lastRead[channel.id] ?? Self.launchDate
        return messages(in: channel).reduce(0) { count, m in
            let counts = m.date > since
                && !m.isReaction && !m.isOutgoing && m.fromId != myNodeId
            return count + (counts ? 1 : 0)
        }
    }

    func markRead(_ channel: MeshChannel) {
        lastRead[channel.id] = .now
        scheduleSave()
    }

    private static let launchDate = Date.now
    /// Каналы подключённой (или последней подключённой) ноды. Пусто — ноды ещё не было.
    var radioChannelNames: [String] = []

    /// Вкладки чата: каналы ноды, а пока ноды не было — все каналы зеркала.
    var visibleChannels: [MeshChannel] {
        radioChannelNames.isEmpty ? MeshChannel.mirrorChannels : radioChannelNames.map(MeshChannel.named)
    }

    func ingestRadio(packetId: Int64, fromId: String, shortName: String?, longName: String?, text: String,
                     channel: String, date: Date, replyTo: Int64?, hops: Int?, snr: Double?,
                     isEmoji: Bool = false, isOutgoing: Bool = false) {
        let key = ChatMessage.key(fromId: fromId, packetId: packetId, fallback: UUID().uuidString)
        if var existing = messages[key] {
            existing.sources.insert(.radio)
            existing.hops = hops ?? existing.hops
            existing.snr = snr ?? existing.snr
            if isEmoji { existing.isReaction = true }
            messages[key] = existing
            return
        }
        messages[key] = ChatMessage(
            id: key, packetId: packetId, fromId: fromId, senderShort: shortName, senderLong: longName,
            text: text, channel: channel, date: date, replyToPacketId: replyTo, sources: [.radio],
            mirrorId: nil, hops: hops, snr: snr, relayCount: 0, isBot: false, isOutgoing: isOutgoing,
            isReaction: isEmoji || Self.looksLikeReaction(text: text, replyTo: replyTo)
        )
    }

    /// Сообщения канала по возрастанию времени. Реакции на загруженные сообщения
    /// не показываются отдельно — они собраны в `reactions(to:)`.
    func messages(in channel: MeshChannel) -> [ChatMessage] {
        index.byChannel[channel.id] ?? []
    }

    struct ReactionGroup: Identifiable {
        struct Sender: Identifiable {
            let nodeId: String
            let shortName: String?
            let longName: String?
            let date: Date
            var id: String { nodeId }
        }

        let emoji: String
        let senders: [Sender]
        var id: String { emoji }
    }

    /// Реакции на сообщение, сгруппированные по эмодзи (в порядке первой реакции).
    func reactions(to packetId: Int64) -> [ReactionGroup] {
        let list = index.reactions[packetId] ?? []
        var order: [String] = []
        var senders: [String: [ReactionGroup.Sender]] = [:]
        for r in list {
            if senders[r.text] == nil { order.append(r.text) }
            // Одна нода — одна реакция каждого вида (повторы по радио/MQTT не считаем).
            guard !(senders[r.text]?.contains { $0.nodeId == r.fromId } ?? false) else { continue }
            senders[r.text, default: []].append(
                .init(nodeId: r.fromId, shortName: r.senderShort, longName: r.senderLong, date: r.date)
            )
        }
        return order.map { ReactionGroup(emoji: $0, senders: senders[$0] ?? []) }
    }

    /// Зеркало не хранит флаг emoji, поэтому реакцию узнаём по виду: ответ из 1–2 эмодзи.
    static func looksLikeReaction(text: String, replyTo: Int64?) -> Bool {
        guard replyTo != nil else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...2).contains(trimmed.count) else { return false }
        return trimmed.allSatisfy { ch in
            ch.unicodeScalars.contains { $0.properties.isEmojiPresentation }
                || (ch.unicodeScalars.first?.properties.isEmoji == true && ch.unicodeScalars.count > 1)
        }
    }

    func ingestMirror(_ batch: [MirrorMessage]) {
        for m in batch {
            guard let text = m.text, !text.isEmpty, let channel = m.channel else { continue }
            let key = ChatMessage.key(fromId: m.fromId, packetId: m.packetId, fallback: "mirror#\(m.id)")
            mirrorIdToKey[m.id] = key

            if var existing = messages[key] {
                existing.sources.insert(.mirror)
                existing.mirrorId = m.id
                existing.relayCount = max(existing.relayCount, m.relays?.count ?? 0)
                existing.senderShort = existing.senderShort ?? m.shortName
                existing.senderLong = existing.senderLong ?? m.longName
                messages[key] = existing
            } else {
                messages[key] = ChatMessage(
                    id: key,
                    packetId: m.packetId,
                    fromId: m.fromId,
                    senderShort: m.shortName,
                    senderLong: m.longName,
                    text: text,
                    channel: channel,
                    date: MirrorJSON.date(m.sentAt) ?? MirrorJSON.date(m.receivedAt) ?? .now,
                    replyToPacketId: m.replyToPacketId,
                    sources: [.mirror],
                    mirrorId: m.id,
                    hops: nil,
                    snr: m.snr,
                    relayCount: m.relays?.count ?? 0,
                    isBot: m.isBot ?? false,
                    isReaction: Self.looksLikeReaction(text: text, replyTo: m.replyToPacketId)
                )
            }
        }
    }

    func applyMirrorRelay(messageId: Int, relay: MirrorRelay) {
        guard let key = mirrorIdToKey[messageId], var message = messages[key] else { return }
        message.relayCount += 1
        messages[key] = message
    }

    /// Подгрузка более старых сообщений зеркала (история общая для всех каналов).
    func loadOlderFromMirror() async {
        guard !isLoadingHistory, let oldest = messages.values.compactMap(\.mirrorId).min() else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        if let older = try? await MirrorAPI.chatHistory(beforeId: oldest) {
            ingestMirror(older)
        }
    }

    func message(packetId: Int64) -> ChatMessage? {
        index.byPacketId[packetId]
    }
}
