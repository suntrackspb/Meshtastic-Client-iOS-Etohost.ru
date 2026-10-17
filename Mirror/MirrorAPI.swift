import Foundation

enum MirrorAPI {
    static var baseURL: URL { AppSettings.mirrorBaseURL }
    static var webSocketURL: URL { AppSettings.mirrorWebSocketURL }

    static func nodes(updatedSince: Date? = nil) async throws -> MirrorNodesResponse {
        var components = URLComponents(url: baseURL.appending(path: "api/nodes"), resolvingAgainstBaseURL: false)!
        if let updatedSince {
            components.queryItems = [URLQueryItem(name: "updated_since", value: updatedSince.ISO8601Format())]
        }
        return try await get(components.url!)
    }

    /// Полная карточка ноды. Отсюда берём публичный ключ, если сервер его отдаёт.
    static func node(id: String) async throws -> MirrorNode {
        try await get(baseURL.appending(path: "api/nodes").appending(path: id))
    }

    static func chatHistory(beforeId: Int, limit: Int = 100) async throws -> [MirrorMessage] {
        var components = URLComponents(url: baseURL.appending(path: "api/chat/history"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "before_id", value: String(beforeId)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        let page: LossyArray<MirrorMessage> = try await get(components.url!)
        return page.elements
    }

    private static func get<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try MirrorJSON.decoder.decode(T.self, from: data)
    }
}
