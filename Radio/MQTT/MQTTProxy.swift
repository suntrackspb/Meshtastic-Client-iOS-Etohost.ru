import CocoaMQTT
import Foundation
import MeshtasticProtobufs
import OSLog
import Security

/// MQTT Client Proxy: нода без Wi-Fi ходит в MQTT через интернет телефона.
/// Логика — MqttClientProxyManager и AccessoryManager+MQTT из Meshtastic-Apple.
@Observable
@MainActor
final class MQTTProxy: NSObject {
    private(set) var isConnected = false
    private(set) var error = ""

    @ObservationIgnored private var client: CocoaMQTT?
    @ObservationIgnored private var topics: [String] = []
    @ObservationIgnored private var forwardBusy = false
    @ObservationIgnored private let sendToRadio: (ToRadio) async throws -> Void
    @ObservationIgnored private var myNodeHex = ""

    init(sendToRadio: @escaping (ToRadio) async throws -> Void) {
        self.sendToRadio = sendToRadio
    }

    /// Подключиться, если в MQTT-конфиге ноды включены enabled и proxyToClientEnabled.
    func start(config: ModuleConfig.MQTTConfig, lora: Config.LoRaConfig?, channels: [Channel], user: User?, myNodeNum: UInt32?) {
        guard config.enabled, config.proxyToClientEnabled else {
            stop()
            return
        }
        guard !isConnected else { return }
        myNodeHex = myNodeNum.map { "!" + String(format: "%08x", $0) } ?? ""

        let originalAddress = config.address.isEmpty ? "mqtt.meshtastic.org" : config.address
        var useSsl = config.tlsEnabled
        var port = useSsl ? 8883 : 1883
        var host = originalAddress
        if originalAddress.contains(":") {
            let parts = originalAddress.components(separatedBy: ":")
            host = parts[0]
            port = Int(parts[1]) ?? port
        }
        // Публичный сервер — только TLS.
        if host.lowercased() == "mqtt.meshtastic.org" {
            useSsl = true
            port = 8883
        }
        let prefix = config.root.isEmpty ? "msh" : config.root

        var newTopics: [String] = []
        for channel in channels where channel.role != .disabled && channel.settings.downlinkEnabled {
            var name = channel.settings.name
            if name.isEmpty, channel.role == .primary {
                if lora?.usePreset ?? true {
                    name = lora?.modemPreset.firmwareChannelName ?? ""
                } else {
                    name = "Custom"
                }
            }
            guard !name.isEmpty else { continue }
            newTopics.append(prefix + "/2/e/" + name + "/+")
        }
        newTopics.append(prefix + "/2/e/PKI/+")
        topics = newTopics

        if config.mapReportingEnabled && !UserDefaults.mapReportingOptIn {
            error = "MQTT Map Reporting Terms need to be accepted."
            return
        }

        let clientId = "MeshtasticAppleMqttProxy-" + (user?.id ?? String(ProcessInfo().processIdentifier)) + "-" + UUID().uuidString
        Logger.mqtt.info("📲 [MQTT] connect \(host, privacy: .public):\(port) ssl=\(useSsl) topics=\(newTopics.joined(separator: ", "), privacy: .public)")
        let mqtt = CocoaMQTT(clientID: clientId, host: host, port: UInt16(port))
        mqtt.enableSSL = useSsl
        mqtt.allowUntrustCACertificate = false
        mqtt.username = config.username
        mqtt.password = config.password
        mqtt.keepAlive = 60
        mqtt.cleanSession = true
        mqtt.willMessage = CocoaMQTTMessage(topic: "/will", string: "dieout")
        mqtt.autoReconnect = true
        mqtt.delegate = self
        client = mqtt
        if !mqtt.connect() {
            error = "Mqtt connect error"
        }
    }

    func stop() {
        client?.autoReconnect = false
        client?.disconnect()
        client = nil
        isConnected = false
    }

    /// Нода → брокер.
    func publish(_ message: MqttClientProxyMessage) {
        let payload: [UInt8]
        switch message.payloadVariant {
        case .data(let bytes): payload = [UInt8](bytes)
        case .text(let string): payload = [UInt8](string.utf8)
        case .none: return
        }
        client?.publish(CocoaMQTTMessage(topic: message.topic, payload: payload, retained: message.retained))
    }

    // MARK: - Брокер → нода

    private func onConnected() {
        isConnected = true
        error = ""
        for topic in topics { client?.subscribe(topic, qos: .qos1) }
    }

    private func onMessage(_ message: CocoaMQTTMessage) {
        if message.topic.contains("/stat/") { return }
        let rawData = Data(message.payload)
        let parsed = try? ServiceEnvelope(serializedData: rawData)
        if let envelope = parsed, MqttForwardFilter.decide(envelope: envelope, myNodeHex: myNodeHex) == .dropNoPayload {
            return
        }
        // hop_limit = 0, чтобы пакеты из MQTT не ретранслировались в эфир.
        var forwardData = rawData
        if var envelope = parsed, envelope.hasPacket, envelope.packet.hopLimit > 0 {
            envelope.packet.hopLimit = 0
            forwardData = (try? envelope.serializedData()) ?? rawData
        }
        var proxyMessage = MqttClientProxyMessage()
        proxyMessage.topic = message.topic
        proxyMessage.data = forwardData
        proxyMessage.retained = message.retained
        var toRadio = ToRadio()
        toRadio.mqttClientProxyMessage = proxyMessage

        // Не больше одной записи в ноду одновременно — лишнее отбрасываем.
        guard !forwardBusy else { return }
        forwardBusy = true
        Task {
            defer { forwardBusy = false }
            try? await sendToRadio(toRadio)
        }
    }

    private func onError(_ message: String) {
        isConnected = false
        error = message
    }
}

extension MQTTProxy: CocoaMQTTDelegate {
    nonisolated func mqtt(_ mqtt: CocoaMQTT, didConnectAck ack: CocoaMQTTConnAck) {
        let description: String? = switch ack {
        case .accept: nil
        case .unacceptableProtocolVersion: "Unacceptable Protocol version"
        case .identifierRejected: "Invalid Id"
        case .serverUnavailable: "Invalid Server"
        case .badUsernameOrPassword: "Invalid Credentials"
        case .notAuthorized: "Authorization Error"
        default: "Unknown Error"
        }
        MainActor.assumeIsolated {
            if let description {
                onError(description)
                mqtt.disconnect()
            } else {
                onConnected()
            }
        }
    }

    nonisolated func mqtt(_ mqtt: CocoaMQTT, didReceive trust: SecTrust, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(SecTrustEvaluateWithError(trust, nil))
    }

    nonisolated func mqttDidDisconnect(_ mqtt: CocoaMQTT, withError err: Error?) {
        let message = err?.localizedDescription
        MainActor.assumeIsolated {
            if let message { error = message }
            isConnected = false
        }
    }

    nonisolated func mqtt(_ mqtt: CocoaMQTT, didReceiveMessage message: CocoaMQTTMessage, id: UInt16) {
        MainActor.assumeIsolated { onMessage(message) }
    }

    nonisolated func mqtt(_ mqtt: CocoaMQTT, didPublishMessage message: CocoaMQTTMessage, id: UInt16) {}
    nonisolated func mqtt(_ mqtt: CocoaMQTT, didPublishAck id: UInt16) {}
    nonisolated func mqtt(_ mqtt: CocoaMQTT, didSubscribeTopics success: NSDictionary, failed: [String]) {}
    nonisolated func mqtt(_ mqtt: CocoaMQTT, didUnsubscribeTopics topics: [String]) {}
    nonisolated func mqttDidPing(_ mqtt: CocoaMQTT) {}
    nonisolated func mqttDidReceivePong(_ mqtt: CocoaMQTT) {}
}
