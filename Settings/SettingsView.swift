import MeshtasticProtobufs
import SwiftUI

/// Настройки подключённой ноды. Разделы, названия и формы — как в Meshtastic-Apple (Settings.swift).
struct SettingsView: View {
    @Environment(RadioManager.self) private var radio

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        AppSettingsView()
                    } label: {
                        Label("Приложение", systemImage: "app.badge")
                    }
                }
                if radio.isConnected, let node = NodeInfoEntity(radio: radio) {
                    SettingsList(node: node, excludedModules: Int(radio.metadata?.excludedModules ?? 0))
                } else {
                    Section {
                        ContentUnavailableView("Нода не подключена", systemImage: "gearshape",
                                               description: Text("Подключите ноду на вкладке «Подключение», чтобы изменить её настройки"))
                    }
                }
            }
            .navigationTitle("Settings")
        }
        .environmentObject(AccessoryManager.shared(radio))
    }
}

private struct SettingsList: View {
    let node: NodeInfoEntity
    let excludedModules: Int

    private func supported(_ module: ExcludedModules) -> Bool {
        excludedModules & module.rawValue == 0
    }

    var body: some View {
        Group {
            Section {
                LabeledContent(node.user?.longName ?? "?", value: node.metadata?.firmwareVersion ?? "")
                if let hw = node.user?.hwModelId, let name = HardwareCatalog.displayName(hwModel: Int(hw)) {
                    Text(name).foregroundStyle(.secondary)
                }
            }

            Section("Radio Configuration") {
                if let region = node.loRaConfig.flatMap({ RegionCodes(rawValue: $0.region.rawValue) }),
                   region.dutyCycle > 0, region.dutyCycle < 100 {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Hourly Duty Cycle", systemImage: "clock.arrow.circlepath")
                        Text("Your region has a \(region.dutyCycle)% hourly duty cycle, your radio will stop sending packets when it reaches the hourly limit.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                link("LoRa", "dot.radiowaves.left.and.right") { LoRaConfig(node: node) }
                link("Channels", "fibrechannel") { ChannelsSettings() }
                link("Share QR Code", "qrcode") { ShareChannels() }
                link("Security", "lock.shield") { SecurityConfig(node: node) }
            }

            Section("Device Configuration") {
                link("User", "person.crop.rectangle.fill") { UserConfig(node: node) }
                link("Bluetooth", "antenna.radiowaves.left.and.right") { BluetoothConfig(node: node) }
                link("Device", "flipphone") { DeviceConfig(node: node) }
                link("Display", "display") { DisplayConfig(node: node) }
                link("Network", "network") { NetworkConfig(node: node) }
                link("Position", "location") { PositionConfig(node: node) }
                link("Power", "bolt.fill") { PowerConfig(node: node) }
            }

            Section("Module Configuration") {
                if supported(.ambientlightingConfig) {
                    link("Ambient Lighting", "light.max") { AmbientLightingConfig(node: node) }
                }
                if supported(.audioConfig) {
                    link("Audio", "waveform") { AudioConfig(node: node) }
                }
                if supported(.cannedmsgConfig) {
                    link("Canned Messages", "list.bullet.rectangle.fill") { CannedMessagesConfig(node: node) }
                }
                if supported(.detectionsensorConfig) {
                    link("Detection Sensor", "sensor") { DetectionSensorConfig(node: node) }
                }
                if supported(.extnotifConfig) {
                    link("External Notification", "megaphone") { ExternalNotificationConfig(node: node) }
                }
                if supported(.mqttConfig) {
                    link("MQTT", "dot.radiowaves.up.forward") { MQTTConfig(node: node) }
                }
                if supported(.neighborinfoConfig) {
                    link("Neighbor Info", "network") { NeighborInfoConfig(node: node) }
                }
                if supported(.rangetestConfig) {
                    link("Range Test", "point.3.connected.trianglepath.dotted") { RangeTestConfig(node: node) }
                }
                if supported(.paxcounterConfig) {
                    link("PAX Counter", "figure.walk.motion") { PaxCounterConfig(node: node) }
                }
                if supported(.serialConfig) {
                    link("Serial", "terminal") { SerialConfig(node: node) }
                }
                if supported(.storeforwardConfig) {
                    link("Store & Forward", "envelope.arrow.triangle.branch") { StoreForwardConfig(node: node) }
                }
                link("TAK", "target") { TAKModuleConfig(node: node) }
                if supported(.telemetryConfig) {
                    link("Telemetry", "chart.xyaxis.line") { TelemetryConfig(node: node) }
                }
                link("Traffic Management", "arrow.triangle.branch") { TrafficManagementConfig(node: node) }
            }
        }
    }

    private func link<V: View>(_ title: LocalizedStringKey, _ symbol: String, @ViewBuilder _ destination: @escaping () -> V) -> some View {
        NavigationLink {
            destination()
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol)
            }
        }
    }
}

// MARK: - Каналы

/// Список каналов по логике Channels.swift из Meshtastic-Apple; редактор — их ChannelForm.
private struct ChannelsSettings: View {
    @Environment(RadioManager.self) private var radio

    @State private var hasChanges = false
    @State private var hasValidKey = true
    @State private var channelIndex: Int32 = 0
    @State private var channelName = ""
    @State private var channelKeySize = 16
    @State private var channelKey = "AQ=="
    @State private var channelRole = 0
    @State private var uplink = false
    @State private var downlink = false
    @State private var positionPrecision = 32.0
    @State private var preciseLocation = true
    @State private var positionsEnabled = true
    @State private var supportedVersion = true
    @State private var editing: EditingChannel?
    @State private var saveError: String?

    private struct EditingChannel: Identifiable {
        let index: Int32
        var id: Int32 { index }
    }

    private var channels: [Channel] { radio.channelSlots.filter { $0.role != .disabled } }
    private var nextSecondaryIndex: Int32? {
        let used = Set(channels.map(\.index))
        return (Int32(1)..<8).first { !used.contains($0) }
    }

    var body: some View {
        List {
            ForEach(channels, id: \.index) { channel in
                Button { open(channel) } label: { ChannelRow(channel: channel, preset: radio.modemPreset) }
                    .buttonStyle(.plain)
            }
            if let next = nextSecondaryIndex {
                Button {
                    channelKeySize = 16
                    channelName = ""
                    channelIndex = next
                    channelRole = 2
                    channelKey = generateChannelKey(size: channelKeySize)
                    positionsEnabled = false
                    preciseLocation = false
                    positionPrecision = 0
                    uplink = false
                    downlink = false
                    hasChanges = true
                    editing = EditingChannel(index: next)
                } label: {
                    Label("Add Channel", systemImage: "plus.square")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Channels")
        .sheet(item: $editing) { _ in
            ChannelForm(channelIndex: $channelIndex, channelName: $channelName, channelKeySize: $channelKeySize,
                        channelKey: $channelKey, channelRole: $channelRole, uplink: $uplink, downlink: $downlink,
                        positionPrecision: $positionPrecision, preciseLocation: $preciseLocation,
                        positionsEnabled: $positionsEnabled, hasChanges: $hasChanges, hasValidKey: $hasValidKey,
                        supportedVersion: $supportedVersion)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            Button {
                save()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .disabled(!radio.isConnected || !hasValidKey)
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .padding(.bottom)
        }
        .alert("Save failed", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    /// Разбор канала в состояние формы — как в официальном Channels.swift.
    private func open(_ channel: Channel) {
        channelIndex = channel.index
        channelRole = channel.role.rawValue
        channelKey = channel.settings.psk.base64EncodedString()
        switch channel.settings.psk.count {
        case 0: channelKeySize = 0
        case 1: channelKeySize = channelKey == "AQ==" ? -1 : 1
        case 16: channelKeySize = 16
        case 24: channelKeySize = 24
        default: channelKeySize = 32
        }
        channelName = channel.settings.name
        uplink = channel.settings.uplinkEnabled
        downlink = channel.settings.downlinkEnabled
        positionPrecision = Double(channel.settings.moduleSettings.positionPrecision)
        if channelKey == "AQ==" {
            preciseLocation = false
            if (positionPrecision > 0 && positionPrecision < 11) || positionPrecision > 14 {
                positionPrecision = 14
            }
        } else if positionPrecision == 32 {
            preciseLocation = true
            positionsEnabled = true
        } else {
            preciseLocation = false
        }
        positionsEnabled = positionPrecision != 0
        hasChanges = false
        editing = EditingChannel(index: channel.index)
    }

    private func save() {
        var channel = Channel()
        channel.index = channelIndex
        channel.role = Channel.Role(rawValue: channelRole) ?? .secondary
        if channel.role != .disabled {
            channel.settings.name = channelName
            channel.settings.psk = Data(base64Encoded: channelKey) ?? Data()
            channel.settings.uplinkEnabled = uplink
            channel.settings.downlinkEnabled = downlink
            channel.settings.moduleSettings.positionPrecision = UInt32(positionPrecision)
        }
        Task {
            do {
                try await radio.saveChannel(channel)
                editing = nil
                hasChanges = false
            } catch {
                saveError = error.localizedDescription
            }
        }
    }
}

private struct ChannelRow: View {
    let channel: Channel
    let preset: String?

    private var title: String {
        if !channel.settings.name.isEmpty { return channel.settings.name }
        if channel.role == .primary { return preset ?? String(localized: "Primary Channel") }
        return String(localized: "Channel \(channel.index)")
    }

    private var subtitle: String {
        channel.role == .primary ? String(localized: "Primary channel") : String(localized: "Channel \(channel.index)")
    }

    private var isEncrypted: Bool { channel.settings.psk.count > 1 }

    var body: some View {
        HStack(spacing: 10) {
            Text("\(channel.index)")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(MeshChannel.named(title).color, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: isEncrypted ? "lock.fill" : "lock.open.fill")
                        .foregroundStyle(isEncrypted ? .green : .yellow)
                        .font(.caption)
                    Text(title).font(.headline)
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if channel.settings.moduleSettings.positionPrecision > 0 {
                Image(systemName: "location.fill").foregroundStyle(.green)
                    .accessibilityLabel(Text("Position sharing"))
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
