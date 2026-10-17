import CoreBluetooth
import Foundation
import OSLog

// Минимальная замена зависимостей, которые транспорты Meshtastic-Apple берут
// из остального приложения (AccessoryManager, Logger, UserDefaults-ключи).

extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "meshmirror"
    static let transport = Logger(subsystem: subsystem, category: "🚚 Transport")
    static let services = Logger(subsystem: subsystem, category: "🍏 Services")
    static let radio = Logger(subsystem: subsystem, category: "📻 Radio")
    static let mesh = Logger(subsystem: subsystem, category: "🕸️ Mesh")
    static let data = Logger(subsystem: subsystem, category: "🗄 Data")
    static let admin = Logger(subsystem: subsystem, category: "🏛 Admin")
    static let mqtt = Logger(subsystem: subsystem, category: "📱 MQTT")
}

extension String {
    var localized: String { NSLocalizedString(self, comment: "") }
}

/// Точки входа, через которые транспорты передают управление нашему RadioManager
/// (в оригинале — прямые вызовы `AccessoryManager.shared`).
enum RadioHooks {
    /// BLE-сессия восстановлена системой после убийства приложения в фоне.
    @MainActor static var onRestore: ((Device, any Connection) async throws -> Void)?
    /// Ручное подключение по IP:порт.
    @MainActor static var onManualConnect: ((Device) async throws -> Void)?

    static func restore(_ device: Device, _ connection: any Connection) async throws {
        try await MainActor.run { onRestore }?(device, connection)
    }

    static func manualConnect(_ device: Device) async throws {
        try await MainActor.run { onManualConnect }?(device)
    }
}

enum BLESignalStrength: Int {
    case weak = 0
    case normal = 1
    case strong = 2
}

enum AccessoryError: Error, LocalizedError {
    case discoveryFailed(String)
    case connectionFailed(String)
    case versionMismatch(String)
    case ioFailed(String)
    case appError(String)
    case timeout
    case disconnected(String)
    case tooManyRetries
    case eventStreamCancelled
    case coreBluetoothError(CBError)
    case coreBluetoothATTError(CBATTError)
    case bondLost

    static let bondLostAdvice = "Нода удалила сохранённое сопряжение, а телефон — нет. Удалите ноду в Настройки → Bluetooth и подключитесь заново."

    var errorDescription: String? {
        switch self {
        case .discoveryFailed(let m): "Ошибка поиска: \(m)"
        case .connectionFailed(let m): "Не удалось подключиться: \(m)"
        case .versionMismatch(let m): "Несовместимая прошивка: \(m)"
        case .ioFailed(let m): "Ошибка связи: \(m)"
        case .appError(let m): "Ошибка приложения: \(m)"
        case .timeout: "Превышено время ожидания"
        case .disconnected(let m): "Отключено: \(m)"
        case .tooManyRetries: "Слишком много попыток"
        case .eventStreamCancelled: "Поток событий отменён"
        case .bondLost: Self.bondLostAdvice
        case .coreBluetoothError(let e):
            switch e.code {
            case .connectionTimeout, .peripheralDisconnected: "Связь с нодой по Bluetooth потеряна, переподключимся автоматически."
            case .peerRemovedPairingInformation: Self.bondLostAdvice
            default: "Ошибка Bluetooth: \(e.localizedDescription)"
            }
        case .coreBluetoothATTError(let e):
            switch e.code {
            case .insufficientAuthentication, .insufficientEncryption: "Ошибка сопряжения. Проверьте PIN и попробуйте снова."
            default: "Ошибка Bluetooth ATT: \(e.localizedDescription)"
            }
        }
    }
}

extension AccessoryError {
    static func forNotifyFailure(_ error: Error, hadBond: Bool) -> Error {
        guard hadBond, BLEConnection.isPairingFailure(error) else { return error }
        return AccessoryError.bondLost
    }
}

extension UserDefaults {
    private enum Key {
        static let preferredPeripheralNum = "preferredPeripheralNum"
        static let pairedPeripheralIds = "pairedPeripheralIds"
        static let manualConnections = "manualConnections"
        static let lastConnectedLongName = "lastConnectedLongName"
        static let lastConnectedShortName = "lastConnectedShortName"
    }

    static var preferredPeripheralNum: Int {
        get { standard.integer(forKey: Key.preferredPeripheralNum) }
        set { standard.set(newValue, forKey: Key.preferredPeripheralNum) }
    }

    static var lastConnectedLongName: String? {
        get { standard.string(forKey: Key.lastConnectedLongName) }
        set { standard.set(newValue, forKey: Key.lastConnectedLongName) }
    }

    static var lastConnectedShortName: String? {
        get { standard.string(forKey: Key.lastConnectedShortName) }
        set { standard.set(newValue, forKey: Key.lastConnectedShortName) }
    }

    private static var pairedPeripheralIds: [String] {
        get { standard.stringArray(forKey: Key.pairedPeripheralIds) ?? [] }
        set { standard.set(newValue, forKey: Key.pairedPeripheralIds) }
    }

    static func isPairedPeripheral(_ id: UUID) -> Bool {
        pairedPeripheralIds.contains(id.uuidString)
    }

    static func rememberPairedPeripheral(_ id: UUID) {
        var ids = Set(pairedPeripheralIds)
        guard ids.insert(id.uuidString).inserted else { return }
        pairedPeripheralIds = ids.sorted()
    }

    static func forgetPairedPeripheral(_ id: UUID) {
        var ids = Set(pairedPeripheralIds)
        guard ids.remove(id.uuidString) != nil else { return }
        pairedPeripheralIds = ids.sorted()
    }

    static var manualConnections: [Device] {
        get {
            guard let data = standard.data(forKey: Key.manualConnections) else { return [] }
            return (try? JSONDecoder().decode([Device].self, from: data)) ?? []
        }
        set {
            standard.set(try? JSONEncoder().encode(newValue), forKey: Key.manualConnections)
        }
    }
}
