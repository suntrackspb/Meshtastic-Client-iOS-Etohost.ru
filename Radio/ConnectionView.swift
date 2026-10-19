import SwiftUI

struct ConnectionView: View {
    @Environment(RadioManager.self) private var radio
    @State private var manualAddress = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    CurrentRadioCard()
                    if radio.isConnected {
                        ConnectedStats()
                            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 12, trailing: 12))
                    }
                }

                if case .poweredOffStatus = bluetoothHint {
                    Section {
                        Label("Bluetooth выключен", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    let devices = radio.discovered
                        .filter { $0.id != radio.connectedDevice?.id }
                        .sorted { ($0.rssi ?? -200) > ($1.rssi ?? -200) }
                    if devices.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Ищем ноды рядом…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(devices) { device in
                        Button {
                            connect(device)
                        } label: {
                            DeviceRow(device: device, isPreferred: device.id == radio.preferredDeviceId)
                        }
                        .tint(.primary)
                    }
                } header: {
                    Text("Найденные ноды")
                } footer: {
                    Text("Bluetooth и Wi-Fi (TCP, mDNS) ищутся одновременно. Последняя нода подключается автоматически.")
                }

                Section {
                    HStack {
                        TextField("192.168.1.50 или meshtastic.local", text: $manualAddress)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .onSubmit(connectManual)
                        Button("Подключить", action: connectManual)
                            .disabled(manualAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Wi-Fi вручную")
                } footer: {
                    Text("Порт по умолчанию 4403. Можно указать адрес:порт.")
                }
            }
            .navigationTitle("Подключение")
            .alert("Ошибка подключения", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
            .onAppear { radio.startDiscovery() }
        }
    }

    private enum BluetoothHint { case ok, poweredOffStatus }

    private var bluetoothHint: BluetoothHint {
        if case .error(let message) = radio.bluetoothStatus, message == BLETransport.poweredOffStatusMessage {
            return .poweredOffStatus
        }
        return .ok
    }

    private func connect(_ device: Device) {
        Task {
            do { try await radio.connect(to: device) } catch { self.error = error.localizedDescription }
        }
    }

    private func connectManual() {
        let address = manualAddress.trimmingCharacters(in: .whitespaces)
        guard let device = radio.device(forManualAddress: address) else {
            error = "Неверный адрес: \(address)"
            return
        }
        connect(device)
    }
}

private struct CurrentRadioCard: View {
    @Environment(RadioManager.self) private var radio

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 44, height: 44)
                .background(color.opacity(0.15), in: Circle())
                .symbolEffect(.pulse, isActive: isBusy)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if radio.connectedDevice != nil || isBusy {
                Button("Отключить", role: .destructive) {
                    Task { await radio.disconnect() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private var isBusy: Bool {
        switch radio.state {
        case .connecting, .configuring, .reconnecting: true
        default: false
        }
    }

    private var icon: String {
        radio.connectedDevice?.transportType == .tcp ? "network" : "dot.radiowaves.left.and.right"
    }

    private var color: Color {
        switch radio.state {
        case .connected: .green
        case .failed: .red
        case .disconnected: .secondary
        default: .orange
        }
    }

    private var title: String {
        switch radio.state {
        case .connected: radio.connectedDevice?.longName ?? radio.connectedDevice?.name ?? "Подключено"
        case .connecting(let name): "Подключение к \(name)…"
        case .configuring(let name): "\(name): загрузка настроек…"
        case .reconnecting(_, let attempt): "Переподключение (\(attempt))…"
        case .failed: "Ошибка"
        case .disconnected: "Нода не подключена"
        }
    }

    private var subtitle: String {
        switch radio.state {
        case .connected:
            [radio.myNodeId, radio.modemPreset, radio.firmwareVersion.map { "v\($0)" }]
                .compactMap { $0 }.joined(separator: " · ")
        case .failed(let reason), .reconnecting(let reason, _): reason
        case .disconnected: "Выберите ноду ниже"
        default: "Получаем NodeDB и каналы"
        }
    }
}

/// Короткая сводка по подключённой ноде.
private struct ConnectedStats: View {
    @Environment(RadioManager.self) private var radio
    @Environment(NodesStore.self) private var nodes

    var body: some View {
        let radioNodes = nodes.nodes.values.filter { $0.sources.contains(.radio) }
        let online = radioNodes.filter(\.isOnline).count
        let me = radio.myNodeId.flatMap { nodes.nodes[$0] }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8)], spacing: 8) {
            StatTile(value: "\(radioNodes.count)", title: "Нод в эфире", systemImage: "antenna.radiowaves.left.and.right", tint: .teal)
            StatTile(value: "\(online)", title: "Онлайн", systemImage: "circle.fill", tint: .green)
            StatTile(value: "\(radio.channels.count)", title: "Каналов", systemImage: "number", tint: .blue)
            if let battery = me?.batteryLevel {
                StatTile(value: battery > 100 ? "Сеть" : "\(battery)%", title: "Батарея",
                         systemImage: battery > 100 ? "powerplug.fill" : "battery.75percent",
                         tint: battery <= 20 ? .red : .green)
            }
            if let util = me?.channelUtilization {
                StatTile(value: String(format: "%.1f%%", util), title: "Загрузка канала",
                         systemImage: "waveform.path.ecg", tint: util > 25 ? .orange : .purple)
            }
            if let air = me?.airUtilTx {
                StatTile(value: String(format: "%.1f%%", air), title: "Эфир TX",
                         systemImage: "arrow.up.circle", tint: .indigo)
            }
        }
    }
}

private struct DeviceRow: View {
    let device: Device
    let isPreferred: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.transportType == .tcp ? "network" : "dot.radiowaves.left.and.right")
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(device.longName ?? device.name).font(.body)
                    if isPreferred {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                }
                Text(device.transportType == .tcp ? device.identifier : "Bluetooth")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let strength = device.getSignalStrength() {
                Image(systemName: "cellularbars", variableValue: Double(strength.rawValue + 1) / 3)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Сигнал \(device.rssiString)")
            }
        }
    }
}
