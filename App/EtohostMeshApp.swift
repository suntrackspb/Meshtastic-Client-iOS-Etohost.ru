import SwiftUI

@main
struct EtohostMeshApp: App {
    @State private var chat: ChatStore
    @State private var nodes: NodesStore
    @State private var direct: DirectStore
    @State private var mirror: MirrorRealtime
    @State private var radio: RadioManager
    @State private var router = AppRouter()

    init() {
        let chat = ChatStore()
        let nodes = NodesStore()
        let direct = DirectStore()
        _chat = State(initialValue: chat)
        _nodes = State(initialValue: nodes)
        _direct = State(initialValue: direct)
        _mirror = State(initialValue: MirrorRealtime(chat: chat, nodes: nodes))
        let radio = RadioManager(chat: chat, nodes: nodes, direct: direct)
        _radio = State(initialValue: radio)
        // Поиск запускаем сразу: так приложение само подключится к последней ноде.
        radio.startDiscovery()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(chat)
                .environment(nodes)
                .environment(direct)
                .environment(mirror)
                .environment(radio)
                .environment(router)
        }
    }
}

/// Переходы между вкладками (например, «Написать» из списка нод → диалог в «Личных»).
@MainActor
@Observable
final class AppRouter {
    enum Tab: Hashable { case chat, direct, nodes, connection, settings }

    #if DEBUG
    /// Для скриншотов в симуляторе: `-startTab settings`.
    var tab: Tab = UserDefaults.standard.string(forKey: "startTab") == "settings" ? .settings : .chat
    #else
    var tab: Tab = .chat
    #endif
    var directPath: [UInt32] = []

    func openConversation(with peer: UInt32) {
        directPath = [peer]
        tab = .direct
    }
}
