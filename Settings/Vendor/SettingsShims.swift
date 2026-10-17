import Combine
import CoreLocation
import Foundation
import MeshtasticProtobufs
import SwiftUI

// Прослойка между экранами настроек Meshtastic-Apple и нашим RadioManager.
// Формы перенесены почти дословно; здесь — минимальные заменители SwiftData-сущностей
// и AccessoryManager, через которые они читают конфиг ноды и отправляют AdminMessage.
// Настраиваем только подключённую ноду, поэтому from == to и session passkey не нужен.

/// Сообщение конфигурации, которое форма читает из того, что прислала нода.
protocol ConfigFormMessage: ConfigSchemaMessage {
    @MainActor static func current(in radio: RadioManager) -> Self?
}

private extension RadioManager {
    func config<T>(_ name: String, _ value: T) -> T? { receivedConfigs.contains(name) ? value : nil }
}

extension Config.DeviceConfig: ConfigFormMessage {
    static func current(in r: RadioManager) -> Self? { r.config("device", r.localConfig.device) }
}
extension Config.PositionConfig: ConfigFormMessage {
    static func current(in r: RadioManager) -> Self? { r.config("position", r.localConfig.position) }
}
extension Config.PowerConfig: ConfigFormMessage {
    static func current(in r: RadioManager) -> Self? { r.config("power", r.localConfig.power) }
}
extension Config.NetworkConfig: ConfigFormMessage {
    static func current(in r: RadioManager) -> Self? { r.config("network", r.localConfig.network) }
}
extension Config.DisplayConfig: ConfigFormMessage {
    static func current(in r: RadioManager) -> Self? { r.config("display", r.localConfig.display) }
}
extension Config.LoRaConfig: ConfigFormMessage {
    static func current(in r: RadioManager) -> Self? { r.config("lora", r.localConfig.lora) }
}
extension Config.BluetoothConfig: ConfigFormMessage {
    static func current(in r: RadioManager) -> Self? { r.config("bluetooth", r.localConfig.bluetooth) }
}
extension Config.SecurityConfig: ConfigFormMessage {
    static func current(in r: RadioManager) -> Self? { r.config("security", r.localConfig.security) }
}
extension ModuleConfig.MQTTConfig: ConfigFormMessage {
    static func current(in r: RadioManager) -> Self? { r.config("mqtt", r.moduleConfig.mqtt) }
}
extension ModuleConfig.SerialConfig: ConfigFormMessage {
    static func current(in r: RadioManager) -> Self? { r.config("serial", r.moduleConfig.serial) }
}
extension ModuleConfig.ExternalNotificationConfig: ConfigFormMessage {
    static func current(in r: RadioManager) -> Self? { r.config("externalNotification", r.moduleConfig.externalNotification) }
}
extension ModuleConfig.StoreForwardConfig: ConfigFormMessage {
    static func current(in r: RadioManager) -> Self? { r.config("storeForward", r.moduleConfig.storeForward) }
}
extension ModuleConfig.RangeTestConfig: ConfigFormMessage {
    static func current(in r: RadioManager) -> Self? { r.config("rangeTest", r.moduleConfig.rangeTest) }
}
extension ModuleConfig.TelemetryConfig: ConfigFormMessage {
    static func current(in r: RadioManager) -> Self? { r.config("telemetry", r.moduleConfig.telemetry) }
}
extension ModuleConfig.CannedMessageConfig: ConfigFormMessage {
    static func current(in r: RadioManager) -> Self? { r.config("cannedMessage", r.moduleConfig.cannedMessage) }
}
extension ModuleConfig.AudioConfig: ConfigFormMessage {
    static func current(in r: RadioManager) -> Self? { r.config("audio", r.moduleConfig.audio) }
}
extension ModuleConfig.NeighborInfoConfig: ConfigFormMessage {
    static func current(in r: RadioManager) -> Self? { r.config("neighborInfo", r.moduleConfig.neighborInfo) }
}
extension ModuleConfig.AmbientLightingConfig: ConfigFormMessage {
    static func current(in r: RadioManager) -> Self? { r.config("ambientLighting", r.moduleConfig.ambientLighting) }
}
extension ModuleConfig.DetectionSensorConfig: ConfigFormMessage {
    static func current(in r: RadioManager) -> Self? { r.config("detectionSensor", r.moduleConfig.detectionSensor) }
}
extension ModuleConfig.PaxcounterConfig: ConfigFormMessage {
    static func current(in r: RadioManager) -> Self? { r.config("paxcounter", r.moduleConfig.paxcounter) }
}
extension ModuleConfig.TrafficManagementConfig: ConfigFormMessage {
    static func current(in r: RadioManager) -> Self? { r.config("trafficManagement", r.moduleConfig.trafficManagement) }
}
extension ModuleConfig.TAKConfig: ConfigFormMessage {
    static func current(in r: RadioManager) -> Self? { r.config("tak", r.moduleConfig.tak) }
}

// MARK: - Заменители сущностей

final class UserEntity: Equatable {
    var num: Int64
    var longName: String?
    var shortName: String?
    var hwModelId: Int32
    var isLicensed: Bool
    var publicKey: Data?
    var role: Int32
    var unmessagable: Bool

    init(num: Int64, user: User?) {
        unmessagable = user?.isUnmessagable ?? false
        self.num = num
        longName = user?.longName
        shortName = user?.shortName
        hwModelId = Int32(user?.hwModel.rawValue ?? 0)
        isLicensed = user?.isLicensed ?? false
        publicKey = user?.publicKey
        role = Int32(user?.role.rawValue ?? 0)
    }

    static func == (a: UserEntity, b: UserEntity) -> Bool { a.num == b.num }
}

struct CannedMessagesSnapshot {
    var config: ModuleConfig.CannedMessageConfig?
    var messages: String?
}

struct MyInfoSnapshot {
    var pioEnv: String?
    var channels: [Channel]
}

/// Снимок подключённой ноды в том виде, в каком его ждут формы.
final class NodeInfoEntity {
    let num: Int64
    let user: UserEntity?
    let metadata: DeviceMetadata?
    let myInfo: MyInfoSnapshot?
    let deviceConfig: Config.DeviceConfig?
    let loRaConfig: Config.LoRaConfig?
    let mqttConfig: ModuleConfig.MQTTConfig?
    let securityConfig: Config.SecurityConfig?
    let cannedMessageConfig: CannedMessagesSnapshot?
    let rangeTestConfig: ModuleConfig.RangeTestConfig?

    @MainActor
    init?(radio: RadioManager) {
        guard let num = radio.myNodeNum else { return nil }
        self.num = Int64(num)
        user = UserEntity(num: Int64(num), user: radio.myUser)
        metadata = radio.metadata
        myInfo = MyInfoSnapshot(pioEnv: radio.myInfo?.pioEnv, channels: radio.channelSlots)
        deviceConfig = Config.DeviceConfig.current(in: radio)
        loRaConfig = Config.LoRaConfig.current(in: radio)
        mqttConfig = ModuleConfig.MQTTConfig.current(in: radio)
        securityConfig = Config.SecurityConfig.current(in: radio)
        rangeTestConfig = ModuleConfig.RangeTestConfig.current(in: radio)
        cannedMessageConfig = CannedMessagesSnapshot(config: ModuleConfig.CannedMessageConfig.current(in: radio),
                                                     messages: radio.cannedMessages)
    }

    func firmwareAtLeast(_ version: String) -> Bool {
        guard let fw = metadata?.firmwareVersion else { return true }
        return fw.compare(version, options: .numeric) != .orderedAscending
    }

    var knownFirmwareVersion: String? { metadata?.firmwareVersion }
}

// MARK: - AccessoryManager

/// Тот же интерфейс, что у AccessoryManager из Meshtastic-Apple, в объёме, нужном формам.
@MainActor
final class AccessoryManager: ObservableObject {
    let radio: RadioManager

    init(radio: RadioManager) { self.radio = radio }

    private static var instance: AccessoryManager?
    static func shared(_ radio: RadioManager) -> AccessoryManager {
        if let instance, instance.radio === radio { return instance }
        let made = AccessoryManager(radio: radio)
        instance = made
        return made
    }

    var isConnected: Bool { radio.isConnected }
    var activeDeviceNum: Int64? { radio.myNodeNum.map(Int64.init) }
    var loRaRegionPresets: [Config.LoRaConfig.RegionCode: RegionPresetInfo] { radio.loRaRegionPresets }

    func checkIsVersionSupported(forVersion version: String) -> Bool {
        guard let fw = radio.firmwareVersion else { return true }
        return fw.compare(version, options: .numeric) != .orderedAscending
    }

    // Конфиг нода присылает целиком при подключении, отдельный запрос не нужен.
    func requestConfig(fromUser: UserEntity, toUser: UserEntity) async throws {}

    private func save(_ build: (inout Config) -> Void) async throws -> Int64 {
        var config = Config()
        build(&config)
        try await radio.saveConfig(config)
        return 0
    }

    private func save(_ build: (inout ModuleConfig) -> Void) async throws -> Int64 {
        var module = ModuleConfig()
        build(&module)
        try await radio.saveModuleConfig(module)
        return 0
    }

    func saveDeviceConfig(config: Config.DeviceConfig, fromUser: UserEntity, toUser: UserEntity) async throws -> Int64 { try await save { $0.device = config } }
    func savePositionConfig(config: Config.PositionConfig, fromUser: UserEntity, toUser: UserEntity) async throws -> Int64 { try await save { $0.position = config } }
    func savePowerConfig(config: Config.PowerConfig, fromUser: UserEntity, toUser: UserEntity) async throws -> Int64 { try await save { $0.power = config } }
    func saveNetworkConfig(config: Config.NetworkConfig, fromUser: UserEntity, toUser: UserEntity) async throws -> Int64 { try await save { $0.network = config } }
    func saveDisplayConfig(config: Config.DisplayConfig, fromUser: UserEntity, toUser: UserEntity) async throws -> Int64 { try await save { $0.display = config } }
    func saveLoRaConfig(config: Config.LoRaConfig, fromUser: UserEntity, toUser: UserEntity) async throws -> Int64 { try await save { $0.lora = config } }
    func saveBluetoothConfig(config: Config.BluetoothConfig, fromUser: UserEntity, toUser: UserEntity) async throws -> Int64 { try await save { $0.bluetooth = config } }
    func saveSecurityConfig(config: Config.SecurityConfig, fromUser: UserEntity, toUser: UserEntity) async throws -> Int64 { try await save { $0.security = config } }

    func saveMQTTConfig(config: ModuleConfig.MQTTConfig, fromUser: UserEntity, toUser: UserEntity) async throws -> Int64 { try await save { $0.mqtt = config } }
    func saveSerialModuleConfig(config: ModuleConfig.SerialConfig, fromUser: UserEntity, toUser: UserEntity) async throws -> Int64 { try await save { $0.serial = config } }
    func saveExternalNotificationModuleConfig(config: ModuleConfig.ExternalNotificationConfig, fromUser: UserEntity, toUser: UserEntity) async throws -> Int64 { try await save { $0.externalNotification = config } }
    func saveStoreForwardModuleConfig(config: ModuleConfig.StoreForwardConfig, fromUser: UserEntity, toUser: UserEntity) async throws -> Int64 { try await save { $0.storeForward = config } }
    func saveRangeTestModuleConfig(config: ModuleConfig.RangeTestConfig, fromUser: UserEntity, toUser: UserEntity) async throws -> Int64 { try await save { $0.rangeTest = config } }
    func saveTelemetryModuleConfig(config: ModuleConfig.TelemetryConfig, fromUser: UserEntity, toUser: UserEntity) async throws -> Int64 { try await save { $0.telemetry = config } }
    func saveCannedMessageModuleConfig(config: ModuleConfig.CannedMessageConfig, fromUser: UserEntity, toUser: UserEntity) async throws -> Int64 { try await save { $0.cannedMessage = config } }
    func saveAudioModuleConfig(config: ModuleConfig.AudioConfig, fromUser: UserEntity, toUser: UserEntity) async throws -> Int64 { try await save { $0.audio = config } }
    func saveNeighborInfoModuleConfig(config: ModuleConfig.NeighborInfoConfig, fromUser: UserEntity, toUser: UserEntity) async throws -> Int64 { try await save { $0.neighborInfo = config } }
    func saveAmbientLightingModuleConfig(config: ModuleConfig.AmbientLightingConfig, fromUser: UserEntity, toUser: UserEntity) async throws -> Int64 { try await save { $0.ambientLighting = config } }
    func saveDetectionSensorModuleConfig(config: ModuleConfig.DetectionSensorConfig, fromUser: UserEntity, toUser: UserEntity) async throws -> Int64 { try await save { $0.detectionSensor = config } }
    func savePaxcounterModuleConfig(config: ModuleConfig.PaxcounterConfig, fromUser: UserEntity, toUser: UserEntity) async throws -> Int64 { try await save { $0.paxcounter = config } }
    func saveTrafficManagementModuleConfig(config: ModuleConfig.TrafficManagementConfig, fromUser: UserEntity, toUser: UserEntity) async throws -> Int64 { try await save { $0.trafficManagement = config } }
    func saveTAKModuleConfig(config: ModuleConfig.TAKConfig, fromUser: UserEntity, toUser: UserEntity) async throws -> Int64 { try await save { $0.tak = config } }

    func saveCannedMessageModuleMessages(messages: String, fromUser: UserEntity, toUser: UserEntity) async throws -> Int64 {
        try await radio.saveCannedMessages(messages)
        return 0
    }

    func saveUser(config: User, fromUser: UserEntity, toUser: UserEntity) async throws -> Int64 {
        try await radio.saveOwner(longName: config.longName, shortName: config.shortName,
                                  isUnmessagable: config.isUnmessagable)
        return 0
    }

    func saveLicensedUser(ham: HamParameters, fromUser: UserEntity, toUser: UserEntity) async throws -> Int64 {
        try await radio.sendAdminCommand { $0.setHamMode = ham }
        return 0
    }

    func sendReboot(fromUser: UserEntity, toUser: UserEntity) async throws {
        try await radio.sendAdminCommand { $0.rebootSeconds = 5 }
    }

    func sendFactoryReset(fromUser: UserEntity, toUser: UserEntity, resetDevice: Bool = false) async throws {
        try await radio.sendAdminCommand {
            if resetDevice { $0.factoryResetDevice = 5 } else { $0.factoryResetConfig = 5 }
        }
    }

    func sendNodeDBReset(fromUser: UserEntity, toUser: UserEntity, preserveFavorites: Bool = true) async throws {
        try await radio.sendAdminCommand { $0.nodedbReset = preserveFavorites }
    }

    func refreshNodeDatabaseAfterLoRaChange() {}

    func disconnect() async throws { await radio.disconnect() }

    /// Переподключиться к той же ноде (после сброса она перезагружается).
    func reconnect() async {
        guard let device = radio.connectedDevice else { return }
        try? await Task.sleep(for: .seconds(3))
        try? await radio.connect(to: device)
    }

    // MQTT Client Proxy — RadioManager.mqttProxy.
    var mqttError: String { radio.mqttProxy.error }
    var mqttProxyConnected: Bool { radio.mqttProxy.isConnected }
    var mqttManager: MQTTProxyFacade { MQTTProxyFacade(radio: radio) }

    /// Фиксированная позиция из GPS телефона.
    func setFixedPosition(fromUser: UserEntity, channel: Int32) async throws {
        let manager = CLLocationManager()
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        var found: CLLocation?
        for try await update in CLLocationUpdate.liveUpdates() {
            if let location = update.location { found = location; break }
        }
        guard let location = found else { throw AccessoryError.appError("Не удалось получить координаты телефона") }
        var position = Position()
        position.latitudeI = Int32(location.coordinate.latitude * 1e7)
        position.longitudeI = Int32(location.coordinate.longitude * 1e7)
        position.altitude = Int32(location.altitude)
        position.time = UInt32(Date.now.timeIntervalSince1970)
        position.locationSource = .locManual
        try await radio.sendAdminCommand { $0.setFixedPosition = position }
    }

    func removeFixedPosition(fromUser: UserEntity, channel: Int32) async throws {
        try await radio.sendAdminCommand { $0.removeFixedPosition = true }
    }
}

@MainActor
struct MQTTProxyFacade {
    let radio: RadioManager
    func connectFromConfigSettings(node: NodeInfoEntity) { radio.startMQTTProxy() }
    func disconnect() { radio.mqttProxy.stop() }
}

/// Последняя известная позиция телефона (для подбора ближайших MQTT-топиков).
final class LocationsHandler {
    static let shared = LocationsHandler()
    private let manager = CLLocationManager()
    var locationsArray: [CLLocation] { manager.location.map { [$0] } ?? [] }
}

extension UserDefaults {
    static var mapReportingOptIn: Bool {
        get { standard.bool(forKey: "mapReportingOptIn") }
        set { standard.set(newValue, forKey: "mapReportingOptIn") }
    }
}

/// Имена полей как у DeviceMetadataEntity.
extension DeviceMetadata {
    var hasWifi: Bool { hasWifi_p }
    var hasEthernet: Bool { hasEthernet_p }
    var hasBluetooth: Bool { hasBluetooth_p }
    var hasXeddsa: Bool { hasXeddsa_p }
    var hasPKC: Bool { hasPkc_p }
}

extension UserDefaults {
    static var enableDetectionNotifications: Bool {
        get { standard.bool(forKey: "enableDetectionNotifications") }
        set { standard.set(newValue, forKey: "enableDetectionNotifications") }
    }
}
