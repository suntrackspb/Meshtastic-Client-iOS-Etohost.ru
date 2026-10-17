import SwiftUI

struct RootTabView: View {
    @Environment(MirrorRealtime.self) private var mirror
    @Environment(NodesStore.self) private var nodes
    @Environment(DirectStore.self) private var direct
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppSettings.Key.theme) private var theme = AppSettings.Theme.system

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            ChatView()
                .tabItem { Label("Чат", systemImage: "bubble.left.and.bubble.right") }
                .tag(AppRouter.Tab.chat)
            DirectListView()
                .tabItem { Label("Личные", systemImage: "envelope") }
                .badge(direct.totalUnread)
                .tag(AppRouter.Tab.direct)
            NodesView()
                .tabItem { Label("Ноды", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(AppRouter.Tab.nodes)
            ConnectionView()
                .tabItem { Label("Подключение", systemImage: "dot.radiowaves.left.and.right") }
                .tag(AppRouter.Tab.connection)
            SettingsView()
                .tabItem { Label("Настройки", systemImage: "gearshape") }
                .tag(AppRouter.Tab.settings)
        }
        .preferredColorScheme(theme.colorScheme)
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                mirror.resume()
                Task { await nodes.refreshFromMirror() }
            default:
                break
            }
        }
    }
}
