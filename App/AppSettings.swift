import SwiftUI

/// Настройки самого приложения (не ноды). Хранятся в UserDefaults.
enum AppSettings {
    static let defaultMirrorHost = "m.etohost.ru"

    enum Key {
        static let theme = "appTheme"
        static let mirrorEnabled = "mirrorEnabled"
        static let mirrorHost = "mirrorHost"
    }

    enum Theme: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .system: "Как в системе"
            case .light: "Светлая"
            case .dark: "Тёмная"
            }
        }
        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    static var mirrorEnabled: Bool {
        UserDefaults.standard.object(forKey: Key.mirrorEnabled) as? Bool ?? true
    }

    /// Адрес зеркала: можно ввести «m.etohost.ru», «https://m.etohost.ru» или «http://10.0.0.5:8000».
    static var mirrorBaseURL: URL {
        let raw = (UserDefaults.standard.string(forKey: Key.mirrorHost) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedURL(raw) ?? URL(string: "https://\(defaultMirrorHost)")!
    }

    static var mirrorWebSocketURL: URL {
        var components = URLComponents(url: mirrorBaseURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = "/ws"
        components.queryItems = [URLQueryItem(name: "history", value: "1")]
        return components.url!
    }

    static func normalizedURL(_ raw: String) -> URL? {
        guard !raw.isEmpty else { return nil }
        let withScheme = raw.contains("://") ? raw : "https://" + raw
        guard var components = URLComponents(string: withScheme),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty else { return nil }
        components.scheme = scheme
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

/// Экран «Приложение» в настройках.
struct AppSettingsView: View {
    @Environment(MirrorRealtime.self) private var mirror
    @Environment(NodesStore.self) private var nodes
    @AppStorage(AppSettings.Key.theme) private var theme = AppSettings.Theme.system
    @AppStorage(AppSettings.Key.mirrorEnabled) private var mirrorEnabled = true
    @AppStorage(AppSettings.Key.mirrorHost) private var mirrorHost = ""
    @State private var hostDraft = ""
    @State private var confirm: Cleanup?

    private enum Cleanup: Identifiable {
        case messages, nodes, all
        var id: Self { self }
        var title: LocalizedStringKey {
            switch self {
            case .messages: "Удалить все сообщения?"
            case .nodes: "Очистить список нод?"
            case .all: "Сбросить приложение?"
            }
        }
        var message: LocalizedStringKey {
            switch self {
            case .messages: "Лента чата и личные сообщения будут удалены с устройства. Сообщения с зеркала подгрузятся заново."
            case .nodes: "Список нод будет очищен. Ноды зеркала подгрузятся заново, ноды радио — при следующем подключении."
            case .all: "Это действие нельзя отменить."
            }
        }
        var action: LocalizedStringKey {
            switch self {
            case .messages: "Удалить сообщения"
            case .nodes: "Очистить ноды"
            case .all: "Сбросить всё"
            }
        }
    }
    @Environment(ChatStore.self) private var chat
    @Environment(DirectStore.self) private var direct
    @Environment(RadioManager.self) private var radio

    private var draftValid: Bool {
        hostDraft.trimmingCharacters(in: .whitespaces).isEmpty || AppSettings.normalizedURL(hostDraft.trimmingCharacters(in: .whitespaces)) != nil
    }

    var body: some View {
        Form {
            Section("Оформление") {
                Picker("Тема", selection: $theme) {
                    ForEach(AppSettings.Theme.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle(isOn: $mirrorEnabled) {
                    Label("Зеркало", systemImage: "globe")
                }
                TextField(AppSettings.defaultMirrorHost, text: $hostDraft)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .onSubmit(applyHost)
                    .disabled(!mirrorEnabled)
                if !draftValid {
                    Text("Неверный адрес").font(.caption).foregroundStyle(.red)
                }
                if hostDraft != mirrorHost {
                    Button("Применить", action: applyHost).disabled(!draftValid)
                }
            } header: {
                Text("Зеркало")
            } footer: {
                Text("Адрес сервера зеркала: с него приходят чат и ноды из MQTT, и с него же открывается веб-карта шлюзов. Пустое поле — \(AppSettings.defaultMirrorHost). Сейчас: \(AppSettings.mirrorBaseURL.absoluteString)")
            }

            Section {
                Button("Очистить сообщения", role: .destructive) { confirm = .messages }
                Button("Очистить ноды", role: .destructive) { confirm = .nodes }
            } header: {
                Text("Данные")
            }

            Section {
                Button("Сбросить приложение", role: .destructive) { confirm = .all }
            } footer: {
                Text("Удаляет ленту чата, личные сообщения, список нод, запомненную ноду и все настройки приложения — как после установки. Настройки самой ноды не меняются.")
            }
        }
        .confirmationDialog(confirm?.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible, presenting: confirm) { item in
            Button(item.action, role: .destructive) { perform(item) }
        } message: { item in
            Text(item.message)
        }
        .navigationTitle("Приложение")
        .onAppear { hostDraft = mirrorHost }
        .onChange(of: mirrorEnabled) { _, on in
            if on { restartMirror() } else { mirror.stop() }
        }
    }

    private func applyHost() {
        guard draftValid else { return }
        hostDraft = hostDraft.trimmingCharacters(in: .whitespaces)
        guard hostDraft != mirrorHost else { return }
        mirrorHost = hostDraft
        if mirrorEnabled { restartMirror() }
    }

    private func perform(_ item: Cleanup) {
        switch item {
        case .messages:
            chat.clearMessages()
            direct.reset()
            if mirrorEnabled { restartMirror() }
        case .nodes:
            nodes.reset()
            if mirrorEnabled { Task { await nodes.refreshFromMirror(full: true) } }
        case .all:
            Task { await resetAll() }
        }
    }

    private func resetAll() async {
        mirror.stop()
        await radio.resetAll()
        chat.reset()
        direct.reset()
        nodes.reset()
        if let bundleId = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleId)
        }
        hostDraft = ""
        // Зеркало по умолчанию включено — сразу подтягиваем свежие данные.
        restartMirror()
        radio.startDiscovery()
    }

    private func restartMirror() {
        mirror.stop()
        mirror.start()
        Task { await nodes.refreshFromMirror(full: true) }
    }
}
