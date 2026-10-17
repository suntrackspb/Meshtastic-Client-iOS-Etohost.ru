import Foundation
import Observation

/// Личная переписка. Есть только в радио (в зеркале PKI-сообщений нет), поэтому хранится на устройстве.
struct DirectMessage: Identifiable, Codable, Hashable {
    enum Status: String, Codable {
        case sending      // отдано ноде
        case sent         // нода подтвердила отправку в эфир
        case delivered    // ACK от получателя
        case failed
        case received
    }

    var id: UInt32 { packetId }
    let packetId: UInt32
    let peer: UInt32
    let isOutgoing: Bool
    let text: String
    let date: Date
    let replyTo: Int64?
    var hops: Int?
    var status: Status
    var failureReason: String?
}

struct Conversation: Identifiable, Hashable {
    let peer: UInt32
    let last: DirectMessage
    let unread: Int
    var id: UInt32 { peer }
}

@MainActor
@Observable
final class DirectStore {
    private(set) var messages: [UInt32: [DirectMessage]] = [:]
    private var lastRead: [UInt32: Date] = [:]
    /// Открытый сейчас диалог: входящие в него сразу считаются прочитанными.
    var openPeer: UInt32?

    private static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "direct-messages.json")
    }

    private struct Snapshot: Codable {
        var messages: [UInt32: [DirectMessage]]
        var lastRead: [UInt32: Date]
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            messages = snapshot.messages
            lastRead = snapshot.lastRead
        }
    }

    /// Сброс приложения: всё забыть и удалить файл переписки.
    func reset() {
        messages = [:]
        lastRead = [:]
        openPeer = nil
        try? FileManager.default.removeItem(at: Self.fileURL)
    }

    var conversations: [Conversation] {
        messages.compactMap { peer, list in
            guard let last = list.last else { return nil }
            let readUntil = lastRead[peer] ?? .distantPast
            let unread = list.filter { !$0.isOutgoing && $0.date > readUntil }.count
            return Conversation(peer: peer, last: last, unread: unread)
        }
        .sorted { $0.last.date > $1.last.date }
    }

    var totalUnread: Int { conversations.reduce(0) { $0 + $1.unread } }

    func thread(with peer: UInt32) -> [DirectMessage] { messages[peer] ?? [] }

    func markRead(_ peer: UInt32) {
        lastRead[peer] = .now
        save()
    }

    func receive(from peer: UInt32, packetId: UInt32, text: String, replyTo: Int64?, hops: Int?, date: Date) {
        guard !(messages[peer]?.contains { $0.packetId == packetId } ?? false) else { return }
        messages[peer, default: []].append(
            DirectMessage(packetId: packetId, peer: peer, isOutgoing: false, text: text, date: date,
                          replyTo: replyTo, hops: hops, status: .received)
        )
        if openPeer == peer { lastRead[peer] = .now }
        save()
    }

    func addOutgoing(to peer: UInt32, packetId: UInt32, text: String, replyTo: Int64?) {
        messages[peer, default: []].append(
            DirectMessage(packetId: packetId, peer: peer, isOutgoing: true, text: text, date: .now,
                          replyTo: replyTo, status: .sending)
        )
        save()
    }

    /// ACK от самой ноды означает «ушло в эфир», от получателя — «доставлено».
    func applyAck(packetId: UInt32, fromDestination: Bool, ok: Bool, reason: String?) {
        update(packetId) { message in
            if !ok {
                message.status = .failed
                message.failureReason = reason
            } else if fromDestination {
                message.status = .delivered
            } else if message.status == .sending {
                message.status = .sent
            }
        }
    }

    func markFailed(packetId: UInt32, reason: String) {
        update(packetId) {
            $0.status = .failed
            $0.failureReason = reason
        }
    }

    func deleteConversation(_ peer: UInt32) {
        messages[peer] = nil
        lastRead[peer] = nil
        save()
    }

    private func update(_ packetId: UInt32, _ change: (inout DirectMessage) -> Void) {
        for (peer, list) in messages {
            if let i = list.firstIndex(where: { $0.packetId == packetId && $0.isOutgoing }) {
                change(&messages[peer]![i])
                save()
                return
            }
        }
    }

    private func save() {
        let snapshot = Snapshot(messages: messages, lastRead: lastRead)
        let url = Self.fileURL
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        }
    }
}
