import Foundation
import MeshtasticProtobufs
import Observation

/// Роли устройств Meshtastic (имена как в Config.DeviceConfig.Role).
enum NodeRole: String, CaseIterable, Identifiable {
    case CLIENT, CLIENT_MUTE, CLIENT_HIDDEN, CLIENT_BASE, TRACKER, SENSOR, ROUTER, ROUTER_LATE, REPEATER, TAK, TAK_TRACKER, LOST_AND_FOUND

    var id: String { rawValue }

    /// Значение Config.DeviceConfig.Role из протобафа.
    init?(protoValue: Int) {
        let map: [Int: NodeRole] = [
            0: .CLIENT, 1: .CLIENT_MUTE, 2: .ROUTER, 4: .REPEATER, 5: .TRACKER, 6: .SENSOR,
            7: .TAK, 8: .CLIENT_HIDDEN, 9: .LOST_AND_FOUND, 10: .TAK_TRACKER, 11: .ROUTER_LATE, 12: .CLIENT_BASE,
        ]
        guard let role = map[protoValue] else { return nil }
        self = role
    }

    var title: String {
        switch self {
        case .CLIENT: "Client"
        case .CLIENT_MUTE: "Client Mute"
        case .CLIENT_HIDDEN: "Client Hidden"
        case .CLIENT_BASE: "Client Base"
        case .TRACKER: "Tracker"
        case .SENSOR: "Sensor"
        case .ROUTER: "Router"
        case .ROUTER_LATE: "Router Late"
        case .REPEATER: "Repeater"
        case .TAK: "TAK"
        case .TAK_TRACKER: "TAK Tracker"
        case .LOST_AND_FOUND: "Lost & Found"
        }
    }

    var symbol: String {
        switch self {
        case .ROUTER, .ROUTER_LATE, .REPEATER: "antenna.radiowaves.left.and.right"
        case .TRACKER, .TAK_TRACKER: "location"
        case .SENSOR: "sensor"
        case .CLIENT_BASE: "house"
        case .CLIENT_HIDDEN: "eye.slash"
        case .CLIENT_MUTE: "speaker.slash"
        default: "iphone.radiowaves.left.and.right"
        }
    }
}

struct MeshNode: Identifiable {
    let id: String              // "!aca96204"
    var shortName: String?
    var longName: String?
    var role: NodeRole?
    var modemPreset: String?
    var lastHeard: Date?
    var latitude: Double?
    var longitude: Double?
    var batteryLevel: Int?
    var snr: Double?
    /// Хопы до ноды — известны только из NodeDB подключённой ноды.
    var hopsAway: Int?
    var sources: Set<MessageSource> = []
    var isFavorite = false
    var isIgnored = false
    var hwModel: Int?
    var channel: UInt32 = 0
    var hasPublicKey = false
    /// Публичный ключ для PKI-лички — из NodeDB радио или с зеркала.
    var publicKey: Data?
    var isUnmessagable = false
    var altitude: Int?
    var voltage: Double?
    var channelUtilization: Double?
    var airUtilTx: Double?
    var uptime: Int?
    var viaMqtt = false

    var hasPosition: Bool { latitude != nil && longitude != nil }
    var displayName: String { longName ?? shortName ?? id }
}

@MainActor
@Observable
final class NodesStore {
    private(set) var nodes: [String: MeshNode] = [:]
    private(set) var isLoading = false
    private(set) var lastError: String?
    private var mirrorGeneratedAt: Date?

    func refreshFromMirror(full: Bool = false) async {
        guard !isLoading, AppSettings.mirrorEnabled else { return }
        if full { mirrorGeneratedAt = nil }
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await MirrorAPI.nodes(updatedSince: mirrorGeneratedAt)
            upsertMirror(response.nodes)
            mirrorGeneratedAt = MirrorJSON.date(response.generatedAt)
            lastError = nil
        } catch {
            lastError = nodes.isEmpty ? "Не удалось загрузить ноды зеркала" : nil
        }
    }

    func upsertMirror(_ batch: [MirrorNode]) {
        for n in batch {
            var node = nodes[n.nodeId] ?? MeshNode(id: n.nodeId)
            node.shortName = n.shortName ?? node.shortName
            node.longName = n.longName ?? node.longName
            node.role = n.role.flatMap(NodeRole.init(rawValue:)) ?? node.role
            node.modemPreset = n.modemPreset ?? node.modemPreset
            node.latitude = n.lastLat ?? node.latitude
            node.longitude = n.lastLon ?? node.longitude
            node.batteryLevel = n.batteryLevel ?? node.batteryLevel
            node.snr = node.snr ?? n.lastSnr
            if let seen = MirrorJSON.date(n.lastSeenAt), seen > (node.lastHeard ?? .distantPast) {
                node.lastHeard = seen
            }
            if let key = n.publicKeyData {
                node.publicKey = key
                node.hasPublicKey = true
            } else if n.hasPublicKey == true {
                node.hasPublicKey = true
            }
            node.sources.insert(.mirror)
            nodes[n.nodeId] = node
        }
    }

    // MARK: - Радио (NodeDB подключённой ноды)

    func upsertRadio(_ info: NodeInfo) {
        let id = NodeID.string(info.num)
        var node = nodes[id] ?? MeshNode(id: id)
        if info.hasUser { apply(info.user, to: &node) }
        if info.hasPosition { apply(info.position, to: &node) }
        if info.hasDeviceMetrics {
            let m = info.deviceMetrics
            if m.hasBatteryLevel { node.batteryLevel = Int(m.batteryLevel) }
            if m.hasVoltage { node.voltage = Double(m.voltage) }
            if m.hasChannelUtilization { node.channelUtilization = Double(m.channelUtilization) }
            if m.hasAirUtilTx { node.airUtilTx = Double(m.airUtilTx) }
            if m.hasUptimeSeconds { node.uptime = Int(m.uptimeSeconds) }
        }
        node.isIgnored = info.isIgnored
        node.channel = info.channel
        node.viaMqtt = info.viaMqtt
        if info.hasHopsAway { node.hopsAway = Int(info.hopsAway) }
        if info.snr != 0 { node.snr = Double(info.snr) }
        if info.lastHeard > 0 { bumpLastHeard(&node, Date(timeIntervalSince1970: TimeInterval(info.lastHeard))) }
        node.isFavorite = info.isFavorite
        node.sources.insert(.radio)
        nodes[id] = node
    }

    func upsertRadioUser(num: UInt32, user: User) {
        let id = NodeID.string(num)
        var node = nodes[id] ?? MeshNode(id: id)
        apply(user, to: &node)
        node.sources.insert(.radio)
        nodes[id] = node
    }

    func updateRadioPosition(num: UInt32, position: Position) {
        let id = NodeID.string(num)
        guard var node = nodes[id] else { return }
        apply(position, to: &node)
        nodes[id] = node
    }

    /// Любой пакет из эфира: нода слышна сейчас, обновляем хопы и SNR.
    func touchRadio(num: UInt32, hops: Int?, snr: Double?) {
        let id = NodeID.string(num)
        var node = nodes[id] ?? MeshNode(id: id)
        bumpLastHeard(&node, .now)
        if let hops { node.hopsAway = hops }
        if let snr, hops == 0 { node.snr = snr }
        node.sources.insert(.radio)
        nodes[id] = node
    }

    private func apply(_ user: User, to node: inout MeshNode) {
        if !user.longName.isEmpty { node.longName = user.longName }
        if !user.shortName.isEmpty { node.shortName = user.shortName }
        node.role = NodeRole(protoValue: user.role.rawValue) ?? node.role
        node.hwModel = user.hwModel.rawValue
        if !user.publicKey.isEmpty {
            node.hasPublicKey = true
            node.publicKey = user.publicKey
        }
        if user.hasIsUnmessagable { node.isUnmessagable = user.isUnmessagable }
    }

    @ObservationIgnored private var keyRequests: [String: Date] = [:]

    /// Ключ ноды: известный или запрошенный с зеркала (не чаще раза в 10 минут на ноду).
    func publicKey(for id: String) async -> Data? {
        if let key = nodes[id]?.publicKey { return key }
        guard AppSettings.mirrorEnabled else { return nil }
        if let last = keyRequests[id], Date.now.timeIntervalSince(last) < 600 { return nil }
        keyRequests[id] = .now
        guard let detail = try? await MirrorAPI.node(id: id), detail.publicKeyData != nil || detail.hasPublicKey == true else { return nil }
        upsertMirror([detail])
        return nodes[id]?.publicKey
    }

    /// Сброс приложения.
    func reset() {
        nodes = [:]
        mirrorGeneratedAt = nil
        keyRequests = [:]
        lastError = nil
    }

    func setFavorite(num: UInt32, _ value: Bool) { nodes[NodeID.string(num)]?.isFavorite = value }
    func setIgnored(num: UInt32, _ value: Bool) { nodes[NodeID.string(num)]?.isIgnored = value }

    /// Нода удалена из NodeDB радио; если её знает зеркало — оставляем.
    func removeRadio(num: UInt32) {
        let id = NodeID.string(num)
        guard var node = nodes[id] else { return }
        node.sources.remove(.radio)
        nodes[id] = node.sources.isEmpty ? nil : node
    }

    private func apply(_ position: Position, to node: inout MeshNode) {
        guard position.latitudeI != 0 || position.longitudeI != 0 else { return }
        if position.hasAltitude { node.altitude = Int(position.altitude) }
        node.latitude = Double(position.latitudeI) * 1e-7
        node.longitude = Double(position.longitudeI) * 1e-7
    }

    private func bumpLastHeard(_ node: inout MeshNode, _ date: Date) {
        if date > (node.lastHeard ?? .distantPast) { node.lastHeard = date }
    }

    var modemPresets: [String] {
        Array(Set(nodes.values.compactMap(\.modemPreset))).sorted()
    }
}
