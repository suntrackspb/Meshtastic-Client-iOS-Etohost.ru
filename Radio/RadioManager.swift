import Foundation
import MeshtasticProtobufs
import Observation
import OSLog

/// Связь с нодой Meshtastic поверх транспортов из Meshtastic-Apple (BLE / TCP).
/// Компактная замена AccessoryManager: handshake, разбор FromRadio, отправка текста.
@MainActor
@Observable
final class RadioManager {
    enum State: Equatable {
        case disconnected
        case connecting(String)
        case configuring(String)
        case connected
        case reconnecting(String, attempt: Int)
        case failed(String)
    }

    struct RadioChannel: Identifiable, Hashable {
        let index: Int
        let name: String
        var id: Int { index }
    }

    private(set) var state: State = .disconnected {
        didSet { BackgroundKeeper.shared.setActive(state == .connected) }
    }
    private(set) var discovered: [Device] = []
    private(set) var connectedDevice: Device?
    private(set) var myNodeNum: UInt32?
    private(set) var channels: [RadioChannel] = []
    private(set) var modemPreset: String?
    private(set) var firmwareVersion: String?
    private(set) var bluetoothStatus: TransportStatus = .uninitialized
    /// Конфигурация подключённой ноды — для экрана настроек.
    private(set) var localConfig = LocalConfig()
    private(set) var moduleConfig = LocalModuleConfig()
    /// Какие разделы нода уже прислала (имена вариантов Config/ModuleConfig).
    private(set) var receivedConfigs: Set<String> = []
    private(set) var metadata: DeviceMetadata?
    private(set) var myInfo: MyNodeInfo?
    private(set) var cannedMessages: String?
    /// Какие пресеты разрешены в каждом регионе (прошивка 2.8+).
    private(set) var loRaRegionPresets: [Config.LoRaConfig.RegionCode: RegionPresetInfo] = [:]
    var loraConfig: Config.LoRaConfig? { receivedConfigs.contains("lora") ? localConfig.lora : nil }
    var deviceConfig: Config.DeviceConfig? { receivedConfigs.contains("device") ? localConfig.device : nil }
    private(set) var myUser: User?
    /// Все 8 слотов каналов, включая выключенные.
    private(set) var channelSlots: [Channel] = []

    var isConnected: Bool { state == .connected }
    var myNodeId: String? { myNodeNum.map(NodeID.string) }

    @ObservationIgnored private let chat: ChatStore
    @ObservationIgnored private let nodes: NodesStore
    @ObservationIgnored private let direct: DirectStore
    @ObservationIgnored private let ble = BLETransport()
    @ObservationIgnored private let tcp = TCPTransport()
    @ObservationIgnored private var connection: (any Connection)?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    /// MQTT Client Proxy через интернет телефона.
    @ObservationIgnored private(set) lazy var mqttProxy = MQTTProxy { [weak self] toRadio in
        guard let connection = self?.connection else { return }
        try await connection.send(toRadio)
    }
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var discoveryTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var configNonce: UInt32 = 0
    @ObservationIgnored private var pendingChannels: [RadioChannel] = []
    @ObservationIgnored private var pendingSlots: [Channel] = []
    @ObservationIgnored private var publicKeys: [UInt32: Data] = [:]
    @ObservationIgnored private var userDisconnected = false
    /// Когда от ноды пришёл последний пакет — для таймаута heartbeat.
    @ObservationIgnored private var lastReceived = Date.distantPast

    init(chat: ChatStore, nodes: NodesStore, direct: DirectStore) {
        self.chat = chat
        self.nodes = nodes
        self.direct = direct
        channels = Self.savedChannels
        chat.radioChannelNames = channels.map(\.name)

        RadioHooks.onRestore = { [weak self] device, connection in
            try await self?.connect(to: device, using: connection)
        }
        RadioHooks.onManualConnect = { [weak self] device in
            try await self?.connect(to: device)
        }
        Task { [weak self] in
            guard let self else { return }
            for await status in await ble.statusUpdates() { self.bluetoothStatus = status }
        }
    }

    // MARK: - Поиск

    func startDiscovery() {
        guard discoveryTasks.isEmpty else { return }
        let transports: [any Transport] = [ble, tcp]
        for transport in transports {
            discoveryTasks.append(Task { [weak self] in
                for await event in await transport.discoverDevices() {
                    self?.handleDiscovery(event)
                }
            })
        }
    }

    func stopDiscovery() {
        discoveryTasks.forEach { $0.cancel() }
        discoveryTasks = []
    }

    private func handleDiscovery(_ event: DiscoveryEvent) {
        switch event {
        case .deviceFound(let device), .deviceUpdated(let device):
            if let i = discovered.firstIndex(where: { $0.id == device.id }) {
                discovered[i] = device
            } else {
                discovered.append(device)
            }
            // Автоподключение к последней ноде, когда она появилась в эфире.
            if device.id == Self.preferredDevice?.id, canAutoConnect, !userDisconnected {
                Task { try? await connect(to: device) }
            }
        case .deviceLost(let id):
            discovered.removeAll { $0.id == id }
        case .deviceReportedRssi(let id, let rssi):
            if let i = discovered.firstIndex(where: { $0.id == id }) { discovered[i].rssi = rssi }
        }
    }

    /// Автоподключение при обнаружении: и после разрыва, и после неудачной попытки.
    private var canAutoConnect: Bool {
        switch state {
        case .disconnected, .failed: reconnectTask == nil
        default: false
        }
    }

    func device(forManualAddress address: String) -> Device? {
        tcp.device(forManualConnection: address)
    }

    // MARK: - Подключение

    func connect(to device: Device, using existing: (any Connection)? = nil) async throws {
        userDisconnected = false
        reconnectTask?.cancel()
        reconnectTask = nil
        try await performConnect(to: device, using: existing)
    }

    /// Само подключение. Не трогает reconnectTask: его вызывает и цикл переподключения,
    /// и раньше `connect` отменял сам этот цикл — попытка падала с CancellationError.
    private func performConnect(to device: Device, using existing: (any Connection)? = nil) async throws {
        await teardown()
        state = .connecting(device.name)
        do {
            let transport: any Transport = device.transportType == .tcp ? tcp : ble
            let connection: any Connection
            if let existing {
                connection = existing
            } else {
                connection = try await transport.connect(to: device)
            }
            let events = try await connection.connect()
            self.connection = connection
            connectedDevice = device
            eventTask = Task { [weak self] in
                for await event in events { await self?.handle(event) }
            }

            state = .configuring(device.name)
            pendingChannels = []
            pendingSlots = []
            try await sendHeartbeat()
            configNonce = UInt32.random(in: 100_000...UInt32.max)
            var want = ToRadio()
            want.wantConfigID = configNonce
            try await connection.send(want)
            try await connection.startDrainPendingPackets()

            Self.preferredDevice = device
            if transport.requiresPeriodicHeartbeat { startHeartbeat() }
        } catch {
            Logger.radio.error("Connect failed: \(error.localizedDescription, privacy: .public)")
            await teardown()
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    func disconnect() async {
        userDisconnected = true
        reconnectTask?.cancel()
        try? await connection?.disconnect(withError: nil, shouldReconnect: false)
        await teardown()
        state = .disconnected
    }

    /// Сброс приложения: отключиться и забыть всё, что известно о ноде.
    func resetAll() async {
        await disconnect()
        Self.preferredDevice = nil
        channels = []
        channelSlots = []
        myNodeNum = nil
        myUser = nil
        myInfo = nil
        metadata = nil
        modemPreset = nil
        firmwareVersion = nil
        localConfig = LocalConfig()
        moduleConfig = LocalModuleConfig()
        receivedConfigs = []
        cannedMessages = nil
        traceRoutes = [:]
        publicKeys = [:]
        userDisconnected = false
    }

    /// Забыть ноду: больше не подключаться к ней автоматически.
    func forgetPreferred() {
        Self.preferredDevice = nil
    }

    var preferredDeviceId: UUID? { Self.preferredDevice?.id }

    private func teardown() async {
        mqttProxy.stop()
        eventTask?.cancel()
        heartbeatTask?.cancel()
        eventTask = nil
        heartbeatTask = nil
        // Закрываем сокет: прошивка держит одного TCP-клиента, брошенное соединение мешает новому.
        let old = connection
        connection = nil
        try? await old?.disconnect(withError: nil, shouldReconnect: false)
        connectedDevice = nil
    }

    private func scheduleReconnect(reason: String) {
        guard !userDisconnected, let device = Self.preferredDevice else {
            state = .failed(reason)
            return
        }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            var attempt = 0
            // Пробуем, пока пользователь сам не отключится: нода может перезагружаться долго.
            while !Task.isCancelled {
                attempt += 1
                guard let self else { return }
                self.state = .reconnecting(reason, attempt: attempt)
                try? await Task.sleep(for: .seconds(attempt == 1 ? 1 : min(15, 2 * attempt)))
                if Task.isCancelled { return }
                if (try? await self.performConnect(to: device)) != nil {
                    self.reconnectTask = nil
                    return
                }
            }
        }
    }

    private func sendHeartbeat() async throws {
        var heartbeat = Heartbeat()
        heartbeat.nonce = UInt32.random(in: 2...UInt32.max)
        var toRadio = ToRadio()
        toRadio.payloadVariant = .heartbeat(heartbeat)
        try await connection?.send(toRadio)
    }

    /// Как в Meshtastic-Apple: heartbeat раз в 15 с, если линия молчит. С прошивки 2.7.4 нода
    /// отвечает на него; нет ни одного пакета 5 с — соединение мёртвое, рвём и переподключаемся.
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled else { return }
                if Date().timeIntervalSince(self.lastReceived) < 15 { continue }
                await self.probeConnection()
            }
        }
    }

    /// Проверить, жива ли линия: heartbeat и ожидание любого ответа.
    func probeConnection() async {
        guard let connection, isConnected || isConfiguring else { return }
        let sentAt = Date()
        do {
            try await sendHeartbeat()
        } catch {
            try? await connection.disconnect(withError: AccessoryError.timeout, shouldReconnect: true)
            return
        }
        guard supportsHeartbeatResponse else { return }
        try? await Task.sleep(for: .seconds(5))
        guard (self.connection as AnyObject?) === (connection as AnyObject), lastReceived < sentAt else { return }
        Logger.radio.error("Heartbeat timeout")
        try? await connection.disconnect(withError: AccessoryError.timeout, shouldReconnect: true)
    }

    private var isConfiguring: Bool { if case .configuring = state { true } else { false } }

    private var supportsHeartbeatResponse: Bool {
        guard let version = firmwareVersion else { return true }
        let parts = version.split(separator: ".").prefix(3).map { Int($0.prefix { $0.isNumber }) ?? 0 }
        return parts.lexicographicallyPrecedes([2, 7, 4]) == false
    }

    /// Возврат в приложение: сразу проверить линию, а если связь потеряна — переподключиться без пауз.
    func appDidBecomeActive() {
        if connection != nil {
            Task { await probeConnection() }
        } else if !userDisconnected, Self.preferredDevice != nil {
            switch state {
            case .failed, .reconnecting, .disconnected:
                // Не ждём паузы цикла — пробуем сразу.
                reconnectTask?.cancel()
                reconnectTask = nil
                scheduleReconnect(reason: String(localized: "Связь потеряна"))
            default: break
            }
        }
        startDiscovery()
    }

    // MARK: - Входящие

    private func handle(_ event: ConnectionEvent) async {
        switch event {
        case .data(let fromRadio):
            lastReceived = Date()
            handle(fromRadio)
        case .logMessage:
            lastReceived = Date()
        case .rssiUpdate:
            break
        case .error(let error):
            await teardown()
            scheduleReconnect(reason: error.localizedDescription)
        case .errorWithoutReconnect(let error):
            await teardown()
            state = .failed(error.localizedDescription)
        case .disconnected(let shouldReconnect):
            await teardown()
            if shouldReconnect { scheduleReconnect(reason: "Связь потеряна") } else { state = .disconnected }
        }
    }

    private func handle(_ fromRadio: FromRadio) {
        switch fromRadio.payloadVariant {
        case .myInfo(let info):
            myInfo = info
            myNodeNum = info.myNodeNum
            UserDefaults.preferredPeripheralNum = Int(info.myNodeNum)
        case .nodeInfo(let info):
            if info.hasUser, !info.user.publicKey.isEmpty { publicKeys[info.num] = info.user.publicKey }
            nodes.upsertRadio(info)
            if info.num == myNodeNum {
                myUser = info.user
                UserDefaults.lastConnectedLongName = info.user.longName
                UserDefaults.lastConnectedShortName = info.user.shortName
            }
        case .channel(let channel):
            pendingSlots.removeAll { $0.index == channel.index }
            pendingSlots.append(channel)
            guard channel.role != .disabled else { break }
            pendingChannels.removeAll { $0.index == Int(channel.index) }
            pendingChannels.append(RadioChannel(index: Int(channel.index), name: channel.settings.name))
        case .config(let config):
            apply(config)
        case .moduleConfig(let module):
            apply(module)
        case .regionPresets(let map):
            loRaRegionPresets = map.decoded()
        case .metadata(let metadata):
            firmwareVersion = metadata.firmwareVersion
            self.metadata = metadata
        case .configCompleteID(let id) where id == configNonce:
            applyChannels()
            state = .connected
            startMQTTProxy()
            // Заготовленные сообщения не входят в конфиг — спрашиваем отдельно.
            Task {
                var admin = AdminMessage()
                admin.getCannedMessageModuleMessagesRequest = true
                try? await sendAdmin(admin, wantResponse: true)
            }
        case .packet(let packet):
            handle(packet)
        case .mqttClientProxyMessage(let message):
            mqttProxy.publish(message)
        default:
            break
        }
    }

    /// Подключить или отключить MQTT-прокси по текущему MQTT-конфигу ноды.
    func startMQTTProxy() {
        mqttProxy.start(config: moduleConfig.mqtt, lora: loraConfig, channels: channelSlots, user: myUser, myNodeNum: myNodeNum)
    }

    /// Пустое имя у основного канала означает «имя по пресету» (LongFast, MediumFast…).
    private func applyChannels() {
        let resolved = pendingChannels
            .sorted { $0.index < $1.index }
            .map { ch in
                ch.name.isEmpty ? RadioChannel(index: ch.index, name: modemPreset ?? "Primary") : ch
            }
        channelSlots = pendingSlots.sorted { $0.index < $1.index }
        guard !resolved.isEmpty else { return }
        channels = resolved
        chat.radioChannelNames = resolved.map(\.name)
        Self.savedChannels = resolved
    }

    private func handle(_ packet: MeshPacket) {
        guard case .decoded(let data) = packet.payloadVariant else { return }
        let hops: Int? = packet.hopStart > 0 && packet.hopStart >= packet.hopLimit
            ? Int(packet.hopStart - packet.hopLimit) : nil
        nodes.touchRadio(num: packet.from, hops: hops, snr: packet.rxSnr == 0 ? nil : Double(packet.rxSnr))

        switch data.portnum {
        case .textMessageApp:
            let text = String(decoding: data.payload, as: UTF8.self)
            let replyTo = data.replyID == 0 ? nil : Int64(data.replyID)
            if packet.to == myNodeNum {
                direct.receive(from: packet.from, packetId: packet.id, text: text, replyTo: replyTo, hops: hops,
                               date: receiveDate(packet))
            } else {
                let channelName = channels.first { $0.index == Int(packet.channel) }?.name ?? modemPreset ?? "Primary"
                let node = nodes.nodes[NodeID.string(packet.from)]
                chat.ingestRadio(
                    packetId: Int64(packet.id),
                    fromId: NodeID.string(packet.from),
                    shortName: node?.shortName,
                    longName: node?.longName,
                    text: text,
                    channel: channelName,
                    date: receiveDate(packet),
                    replyTo: replyTo,
                    hops: hops,
                    snr: packet.rxSnr == 0 ? nil : Double(packet.rxSnr),
                    isEmoji: data.emoji != 0
                )
            }
        case .routingApp:
            guard data.requestID != 0, let routing = try? Routing(serializedBytes: data.payload) else { break }
            let ok = routing.errorReason == .none
            direct.applyAck(packetId: data.requestID, fromDestination: packet.from != myNodeNum, ok: ok,
                            reason: ok ? nil : String(describing: routing.errorReason))
        case .nodeinfoApp:
            if let user = try? User(serializedBytes: data.payload) {
                if !user.publicKey.isEmpty { publicKeys[packet.from] = user.publicKey }
                nodes.upsertRadioUser(num: packet.from, user: user)
            }
        case .adminApp:
            guard let admin = try? AdminMessage(serializedBytes: data.payload) else { break }
            if case .getCannedMessageModuleMessagesResponse(let messages) = admin.payloadVariant {
                cannedMessages = messages
            }
        case .positionApp:
            if let position = try? Position(serializedBytes: data.payload) {
                nodes.updateRadioPosition(num: packet.from, position: position)
            }
        case .tracerouteApp:
            guard data.requestID != 0, let pending = pendingTraceRoutes[data.requestID],
                  let route = try? RouteDiscovery(serializedBytes: data.payload) else { break }
            pendingTraceRoutes[data.requestID] = nil
            traceRoutes[pending] = TraceRouteResult(
                date: .now, target: pending,
                towards: route.route, snrTowards: route.snrTowards,
                back: route.routeBack, snrBack: route.snrBack,
                hasBack: packet.hopStart > 0 && !route.snrBack.isEmpty)
        default:
            break
        }
    }

    // MARK: - Отправка

    /// Сообщение в канал. Возвращает id пакета.
    @discardableResult
    func sendChannelMessage(_ text: String, channel: RadioChannel, replyTo: Int64?, isEmoji: Bool = false) async throws -> UInt32 {
        let id = try await sendText(text, to: NodeID.broadcast, channelIndex: UInt32(channel.index),
                                    replyTo: replyTo, isEmoji: isEmoji, pkiKey: nil)
        if let me = myNodeNum {
            let node = nodes.nodes[NodeID.string(me)]
            chat.ingestRadio(packetId: Int64(id), fromId: NodeID.string(me), shortName: node?.shortName,
                             longName: node?.longName, text: text, channel: channel.name, date: .now,
                             replyTo: replyTo, hops: nil, snr: nil, isEmoji: isEmoji, isOutgoing: true)
        }
        return id
    }

    /// Ключ для PKI: сначала NodeDB радио, затем зеркало (если сервер отдаёт ключи).
    private func publicKey(for num: UInt32) async -> Data? {
        if let key = publicKeys[num] { return key }
        return await nodes.publicKey(for: NodeID.string(num))
    }

    func sendDirectMessage(_ text: String, to num: UInt32, replyTo: Int64?) async throws {
        let id = UInt32.random(in: 1...UInt32.max)
        direct.addOutgoing(to: num, packetId: id, text: text, replyTo: replyTo)
        let key = await publicKey(for: num)
        do {
            _ = try await sendText(text, to: num, channelIndex: 0, replyTo: replyTo, pkiKey: key, packetId: id)
        } catch {
            direct.markFailed(packetId: id, reason: error.localizedDescription)
            throw error
        }
    }

    private func sendText(_ text: String, to: UInt32, channelIndex: UInt32, replyTo: Int64?, isEmoji: Bool = false,
                          pkiKey: Data?, packetId: UInt32 = .random(in: 1...UInt32.max)) async throws -> UInt32 {
        guard let connection, isConnected else { throw AccessoryError.disconnected("Нода не подключена") }
        var data = DataMessage()
        data.portnum = .textMessageApp
        data.payload = Data(text.utf8)
        if let replyTo { data.replyID = UInt32(truncatingIfNeeded: replyTo) }
        if isEmoji { data.emoji = 1 }

        var packet = MeshPacket()
        packet.id = packetId
        packet.to = to
        packet.channel = channelIndex
        packet.wantAck = true
        packet.decoded = data
        if let pkiKey, !pkiKey.isEmpty {
            packet.pkiEncrypted = true
            packet.publicKey = pkiKey
        }

        var toRadio = ToRadio()
        toRadio.packet = packet
        try await connection.send(toRadio)
        return packetId
    }

    // MARK: - Настройки ноды (AdminMessage)

    /// Admin-сообщение своей ноде. Для локальной ноды session passkey не нужен.
    private func sendAdmin(_ admin: AdminMessage, wantResponse: Bool = false) async throws {
        guard let connection, isConnected, let me = myNodeNum else {
            throw AccessoryError.disconnected("Нода не подключена")
        }
        var data = DataMessage()
        data.portnum = .adminApp
        data.payload = try admin.serializedData()
        data.wantResponse = wantResponse
        var packet = MeshPacket()
        packet.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
        packet.to = me
        packet.from = me
        packet.priority = .reliable
        packet.wantAck = true
        packet.decoded = data
        var toRadio = ToRadio()
        toRadio.packet = packet
        try await connection.send(toRadio)
    }

    func saveOwner(longName: String, shortName: String, isUnmessagable: Bool) async throws {
        var user = myUser ?? User()
        user.longName = longName
        user.shortName = shortName
        user.isUnmessagable = isUnmessagable
        var admin = AdminMessage()
        admin.setOwner = user
        try await sendAdmin(admin)
        myUser = user
        if let me = myNodeNum { nodes.upsertRadioUser(num: me, user: user) }
        UserDefaults.lastConnectedLongName = longName
        UserDefaults.lastConnectedShortName = shortName
    }

    func saveDeviceConfig(_ device: Config.DeviceConfig) async throws {
        var config = Config()
        config.device = device
        try await saveConfig(config)
    }

    /// Изменение части настроек перезагружает ноду — дальше сработает автопереподключение.
    func saveConfig(_ config: Config) async throws {
        var admin = AdminMessage()
        admin.setConfig = config
        try await sendAdmin(admin)
        apply(config)
    }

    func saveModuleConfig(_ module: ModuleConfig) async throws {
        var admin = AdminMessage()
        admin.setModuleConfig = module
        try await sendAdmin(admin)
        apply(module)
        if case .mqtt = module.payloadVariant {
            mqttProxy.stop()
            startMQTTProxy()
        }
    }

    func saveCannedMessages(_ messages: String) async throws {
        var admin = AdminMessage()
        admin.setCannedMessageModuleMessages = messages
        try await sendAdmin(admin)
        cannedMessages = messages
    }

    func sendAdminCommand(_ build: (inout AdminMessage) -> Void) async throws {
        var admin = AdminMessage()
        build(&admin)
        try await sendAdmin(admin)
    }

    // MARK: - Действия над нодой (как в NodeDetail официального клиента)

    func setFavorite(_ num: UInt32, _ favorite: Bool) async throws {
        try await sendAdminCommand { if favorite { $0.setFavoriteNode = num } else { $0.removeFavoriteNode = num } }
        nodes.setFavorite(num: num, favorite)
    }

    func setIgnored(_ num: UInt32, _ ignored: Bool) async throws {
        try await sendAdminCommand { if ignored { $0.setIgnoredNode = num } else { $0.removeIgnoredNode = num } }
        nodes.setIgnored(num: num, ignored)
    }

    func removeNode(_ num: UInt32) async throws {
        try await sendAdminCommand { $0.removeByNodenum = num }
        nodes.removeRadio(num: num)
    }

    /// Отправить свой User с просьбой прислать их (NodeInfo exchange).
    func exchangeUserInfo(with num: UInt32, channel: UInt32) async throws {
        guard let myUser else { throw AccessoryError.disconnected("Нода не подключена") }
        var data = DataMessage()
        data.portnum = .nodeinfoApp
        data.payload = try myUser.serializedData()
        data.wantResponse = true
        try await sendPacket(data, to: num, channel: channel, priority: .reliable)
    }

    /// Результаты traceroute по номеру ноды-цели.
    private(set) var traceRoutes: [UInt32: TraceRouteResult] = [:]
    @ObservationIgnored private var pendingTraceRoutes: [UInt32: UInt32] = [:]

    func sendTraceRoute(to num: UInt32) async throws {
        var data = DataMessage()
        data.portnum = .tracerouteApp
        data.payload = try RouteDiscovery().serializedData()
        data.wantResponse = true
        let id = try await sendPacket(data, to: num, channel: 0, priority: nil)
        pendingTraceRoutes[id] = num
        traceRoutes[num] = nil
    }

    @discardableResult
    private func sendPacket(_ data: DataMessage, to: UInt32, channel: UInt32, priority: MeshPacket.Priority?) async throws -> UInt32 {
        guard let connection, isConnected, let me = myNodeNum else { throw AccessoryError.disconnected("Нода не подключена") }
        var packet = MeshPacket()
        packet.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
        packet.to = to
        packet.from = me
        packet.channel = channel
        packet.wantAck = true
        if let priority { packet.priority = priority }
        packet.decoded = data
        var toRadio = ToRadio()
        toRadio.packet = packet
        try await connection.send(toRadio)
        return packet.id
    }

    private func apply(_ config: Config) {
        switch config.payloadVariant {
        case .device(let v): localConfig.device = v; receivedConfigs.insert("device")
        case .position(let v): localConfig.position = v; receivedConfigs.insert("position")
        case .power(let v): localConfig.power = v; receivedConfigs.insert("power")
        case .network(let v): localConfig.network = v; receivedConfigs.insert("network")
        case .display(let v): localConfig.display = v; receivedConfigs.insert("display")
        case .lora(let v):
            localConfig.lora = v; receivedConfigs.insert("lora")
            modemPreset = ModemPresetName.name(v.modemPreset)
        case .bluetooth(let v): localConfig.bluetooth = v; receivedConfigs.insert("bluetooth")
        case .security(let v): localConfig.security = v; receivedConfigs.insert("security")
        default: break
        }
    }

    private func apply(_ module: ModuleConfig) {
        switch module.payloadVariant {
        case .mqtt(let v): moduleConfig.mqtt = v; receivedConfigs.insert("mqtt")
        case .serial(let v): moduleConfig.serial = v; receivedConfigs.insert("serial")
        case .externalNotification(let v): moduleConfig.externalNotification = v; receivedConfigs.insert("externalNotification")
        case .storeForward(let v): moduleConfig.storeForward = v; receivedConfigs.insert("storeForward")
        case .rangeTest(let v): moduleConfig.rangeTest = v; receivedConfigs.insert("rangeTest")
        case .telemetry(let v): moduleConfig.telemetry = v; receivedConfigs.insert("telemetry")
        case .cannedMessage(let v): moduleConfig.cannedMessage = v; receivedConfigs.insert("cannedMessage")
        case .audio(let v): moduleConfig.audio = v; receivedConfigs.insert("audio")
        case .remoteHardware(let v): moduleConfig.remoteHardware = v; receivedConfigs.insert("remoteHardware")
        case .neighborInfo(let v): moduleConfig.neighborInfo = v; receivedConfigs.insert("neighborInfo")
        case .ambientLighting(let v): moduleConfig.ambientLighting = v; receivedConfigs.insert("ambientLighting")
        case .detectionSensor(let v): moduleConfig.detectionSensor = v; receivedConfigs.insert("detectionSensor")
        case .paxcounter(let v): moduleConfig.paxcounter = v; receivedConfigs.insert("paxcounter")
        case .trafficManagement(let v): moduleConfig.trafficManagement = v; receivedConfigs.insert("trafficManagement")
        case .tak(let v): moduleConfig.tak = v; receivedConfigs.insert("tak")
        default: break
        }
    }

    func saveChannel(_ channel: Channel) async throws {
        var admin = AdminMessage()
        admin.setChannel = channel
        try await sendAdmin(admin)
        channelSlots.removeAll { $0.index == channel.index }
        channelSlots.append(channel)
        channelSlots.sort { $0.index < $1.index }
        pendingSlots = channelSlots
        pendingChannels = channelSlots.filter { $0.role != .disabled }
            .map { RadioChannel(index: Int($0.index), name: $0.settings.name) }
        applyChannels()
    }

    // MARK: - Сохранённое

    private static var preferredDevice: Device? {
        get { UserDefaults.standard.data(forKey: "preferredDevice").flatMap { try? JSONDecoder().decode(Device.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "preferredDevice") }
    }

    private static var savedChannels: [RadioChannel] {
        get {
            (UserDefaults.standard.array(forKey: "radioChannels") as? [String] ?? [])
                .enumerated().map { RadioChannel(index: $0.offset, name: $0.element) }
        }
        set {
            // Индексы не сохраняем: после переподключения нода всё равно пришлёт актуальные.
            UserDefaults.standard.set(newValue.map(\.name), forKey: "radioChannels")
        }
    }
}

extension UserDefaults {
    /// ID последней подключённой ноды — чтобы узнавать свои сообщения и без подключения.
    static var myNodeId: String? {
        preferredPeripheralNum == 0 ? nil : NodeID.string(UInt32(truncatingIfNeeded: preferredPeripheralNum))
    }
}

enum NodeID {
    static let broadcast: UInt32 = 0xFFFF_FFFF

    static func string(_ num: UInt32) -> String { String(format: "!%08x", num) }

    static func num(_ id: String) -> UInt32? {
        UInt32(id.trimmingCharacters(in: CharacterSet(charactersIn: "!")), radix: 16)
    }
}

enum ModemPresetName {
    static func name(_ preset: Config.LoRaConfig.ModemPreset) -> String {
        switch preset {
        case .longFast: "LongFast"
        case .longSlow: "LongSlow"
        case .veryLongSlow: "VeryLongSlow"
        case .mediumSlow: "MediumSlow"
        case .mediumFast: "MediumFast"
        case .shortSlow: "ShortSlow"
        case .shortFast: "ShortFast"
        case .longModerate: "LongModerate"
        case .shortTurbo: "ShortTurbo"
        case .longTurbo: "LongTurbo"
        default: String(describing: preset).prefix(1).uppercased() + String(describing: preset).dropFirst()
        }
    }
}

struct TraceRouteResult {
    let date: Date
    let target: UInt32
    let towards: [UInt32]
    let snrTowards: [Int32]
    let back: [UInt32]
    let snrBack: [Int32]
    let hasBack: Bool
}

extension RadioManager {
    /// Время сообщения из эфира. Живой пакет — время устройства: часы ноды могут
    /// врать (нет GPS/NTP). Пакеты, которые нода отдаёт при подключении из своей
    /// очереди, — её `rxTime`, если он правдоподобен (не в будущем и не до 2024 года).
    func receiveDate(_ packet: MeshPacket) -> Date {
        let now = Date.now
        guard !isConnected, packet.rxTime != 0 else { return now }
        let rx = Date(timeIntervalSince1970: TimeInterval(packet.rxTime))
        let floor = Date(timeIntervalSince1970: 1_704_067_200) // 2024-01-01
        return rx > floor && rx <= now ? rx : now
    }
}
