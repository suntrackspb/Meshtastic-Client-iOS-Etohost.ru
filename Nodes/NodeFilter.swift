import Foundation

struct NodeFilter: Equatable {
    enum Source: String, CaseIterable, Identifiable {
        case all = "Все"
        case radio = "Радиоэфир"
        case mirror = "Только MQTT"
        var id: String { rawValue }
    }

    enum LastHeard: Int, CaseIterable, Identifiable {
        case any = 0, hour = 3600, twoHours = 7200, day = 86400, week = 604800
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .any: "Любое время"
            case .hour: "1 час"
            case .twoHours: "2 часа"
            case .day: "24 часа"
            case .week: "7 дней"
            }
        }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case lastHeard = "Последняя активность"
        case name = "Имя"
        case hops = "Хопы"
        var id: String { rawValue }
    }

    var source: Source = .all
    var roles: Set<NodeRole> = []
    /// nil — без ограничения. Применяется только к нодам с известными хопами.
    var maxHops: Int?
    var lastHeard: LastHeard = .day
    var withPositionOnly = false
    var favoritesOnly = false
    var modemPreset: String?
    var sort: Sort = .lastHeard

    var activeCount: Int {
        var n = 0
        if source != .all { n += 1 }
        if !roles.isEmpty { n += 1 }
        if maxHops != nil { n += 1 }
        if lastHeard != .any { n += 1 }
        if withPositionOnly { n += 1 }
        if favoritesOnly { n += 1 }
        if modemPreset != nil { n += 1 }
        return n
    }

    func apply(to nodes: some Sequence<MeshNode>, search: String, now: Date = .now) -> [MeshNode] {
        // "!aca96204", "aca96204" и "ACA9" — всё ищется по node id; плюс long/short name.
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let idQuery = query.hasPrefix("!") ? String(query.dropFirst()) : query
        let result = nodes.filter { node in
            switch source {
            case .all: break
            case .radio: guard node.sources.contains(.radio) else { return false }
            case .mirror: guard node.sources == [.mirror] else { return false }
            }
            if !roles.isEmpty, !node.role.map(roles.contains).orFalse { return false }
            if let maxHops, let hops = node.hopsAway, hops > maxHops { return false }
            if lastHeard != .any {
                guard let heard = node.lastHeard, now.timeIntervalSince(heard) <= Double(lastHeard.rawValue) else { return false }
            }
            if withPositionOnly && !node.hasPosition { return false }
            if favoritesOnly && !node.isFavorite { return false }
            if let modemPreset, node.modemPreset != modemPreset { return false }
            if !query.isEmpty {
                let names = [node.shortName, node.longName].compactMap { $0?.lowercased() }
                let idMatch = !idQuery.isEmpty && node.id.lowercased().dropFirst().contains(idQuery)
                guard idMatch || names.contains(where: { $0.contains(query) }) else { return false }
            }
            return true
        }
        // Избранные всегда сверху, внутри групп — выбранная сортировка.
        let ordered: (MeshNode, MeshNode) -> Bool = switch sort {
        case .lastHeard: { ($0.lastHeard ?? .distantPast) > ($1.lastHeard ?? .distantPast) }
        case .name: { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .hops: { ($0.hopsAway ?? .max) < ($1.hopsAway ?? .max) }
        }
        return result.sorted { a, b in
            a.isFavorite != b.isFavorite ? a.isFavorite : ordered(a, b)
        }
    }
}

private extension Optional where Wrapped == Bool {
    var orFalse: Bool { self ?? false }
}
