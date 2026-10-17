import Foundation

enum Architecture: String, Codable, Identifiable {
    case esp32 = "esp32"
    case esp32C3 = "esp32-c3"
    case esp32S3 = "esp32-s3"
    case nrf52840 = "nrf52840"
    case rp2040 = "rp2040"
    case esp32C6 = "esp32-c6"

    var id: String { rawValue }
}

/// Каталог плат из Meshtastic-Apple (Resources/DeviceHardware.json).
enum HardwareCatalog {
    struct Entry: Decodable {
        let hwModel: Int
        let architecture: String
        let displayName: String
        let tags: [String]?
    }

    static let entries: [Int: Entry] = {
        guard let url = Bundle.main.url(forResource: "DeviceHardware", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return [:] }
        return Dictionary(list.map { ($0.hwModel, $0) }, uniquingKeysWith: { a, _ in a })
    }()

    static func architecture(hwModel: Int) -> Architecture? {
        entries[hwModel].flatMap { Architecture(rawValue: $0.architecture) }
    }

    static func displayName(hwModel: Int) -> String? { entries[hwModel]?.displayName }
}
