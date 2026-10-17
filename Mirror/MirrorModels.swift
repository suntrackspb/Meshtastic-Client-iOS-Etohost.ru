import Foundation

/// Сообщение в формате зеркала (`/api/chat`, WS `init` / `new_message`).
struct MirrorMessage: Decodable {
    let id: Int
    let packetId: Int64?
    let fromId: String
    let toId: String?
    let text: String?
    let replyToPacketId: Int64?
    let city: String?
    let snr: Double?
    let rssi: Int?
    let channel: String?
    let receivedAt: String?
    let sentAt: String?
    let shortName: String?
    let longName: String?
    let isBot: Bool?
    let relays: [MirrorRelay]?
}

struct MirrorRelay: Decodable {
    let nodeId: String?
    let snr: Double?
    let rssi: Int?
    let hops: Int?
    let relayNodeId: String?
    let shortName: String?
    let longName: String?
}

/// Нода зеркала. Все поля опциональны: `/api/nodes` и WS `node_update` отдают разный набор.
struct MirrorNode: Decodable {
    let nodeId: String
    let longName: String?
    let shortName: String?
    let role: String?
    let modemPreset: String?
    let hwModel: Int?
    let lastLat: Double?
    let lastLon: Double?
    let lastSeenAt: String?
    let batteryLevel: Int?
    let lastSnr: Double?
    /// Пока сервер их не отдаёт — nil; появятся без пересборки приложения.
    let hasPublicKey: Bool?
    let publicKey: String?

    /// Ключ приходит hex-строкой (как пишет сервер), на всякий случай понимаем и base64.
    var publicKeyData: Data? {
        guard let publicKey, !publicKey.isEmpty else { return nil }
        if publicKey.count == 64, let data = Data(hexString: publicKey) { return data }
        if let data = Data(base64Encoded: publicKey), data.count == 32 { return data }
        return nil
    }
}

extension Data {
    init?(hexString: String) {
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2, limitedBy: hexString.endIndex) ?? hexString.endIndex
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

struct MirrorNodesResponse: Decodable {
    let nodes: [MirrorNode]
    let count: Int
    let generatedAt: String
}

/// Кадры WebSocket `/ws`.
enum MirrorEvent {
    case initial([MirrorMessage])
    case newMessage(MirrorMessage)
    case relayUpdate(messageId: Int, relay: MirrorRelay)
    case nodeUpdate(MirrorNode)
    case other

    private struct Envelope: Decodable { let type: String }
    private struct Initial: Decodable { let messages: LossyArray<MirrorMessage> }
    private struct New: Decodable { let message: MirrorMessage }
    private struct Relay: Decodable { let messageId: Int; let relay: MirrorRelay }
    private struct NodeUpd: Decodable { let node: MirrorNode }

    static func decode(_ data: Data) throws -> MirrorEvent {
        let d = MirrorJSON.decoder
        switch try d.decode(Envelope.self, from: data).type {
        case "init": return .initial(try d.decode(Initial.self, from: data).messages.elements)
        case "new_message": return .newMessage(try d.decode(New.self, from: data).message)
        case "relay_update":
            let r = try d.decode(Relay.self, from: data)
            return .relayUpdate(messageId: r.messageId, relay: r.relay)
        case "node_update": return .nodeUpdate(try d.decode(NodeUpd.self, from: data).node)
        default: return .other
        }
    }
}

/// Массив, в котором нераспознанные элементы пропускаются, а не валят весь разбор.
/// В ленте зеркала вперемешку с сообщениями лежат события `name_change` со строковым `id`.
struct LossyArray<Element: Decodable>: Decodable {
    let elements: [Element]

    private struct Skip: Decodable {}

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                result.append(element)
            } else {
                _ = try? container.decode(Skip.self)
            }
        }
        elements = result
    }
}

enum MirrorJSON {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private static let isoNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Бэкенд отдаёт и `2026-10-09 19:20:32.127335+00:00`, и `2026-10-09T19:02:01.107651Z`:
    /// дробную часть с микросекундами ISO8601DateFormatter не понимает, поэтому разбираем её отдельно.
    static func date(_ raw: String?) -> Date? {
        guard var s = raw?.replacingOccurrences(of: " ", with: "T") else { return nil }
        var fraction: Double = 0
        if let dot = s.firstIndex(of: ".") {
            let end = s[dot...].firstIndex { $0 == "Z" || $0 == "+" || $0 == "-" } ?? s.endIndex
            fraction = Double("0" + s[dot..<end]) ?? 0
            s.removeSubrange(dot..<end)
        }
        return isoNoFraction.date(from: s)?.addingTimeInterval(fraction)
    }
}
