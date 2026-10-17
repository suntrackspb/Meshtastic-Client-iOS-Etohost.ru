import MapKit
import SwiftUI

/// Карточка ноды. Разделы и действия — по NodeDetail.swift из Meshtastic-Apple.
struct NodeDetailView: View {
    let nodeId: String

    @Environment(NodesStore.self) private var store
    @Environment(RadioManager.self) private var radio
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    @State private var alert: AlertInfo?
    @State private var confirmDelete = false
    @State private var confirmClientBaseFavorite = false
    @State private var traceRouteCooldownUntil: Date?

    private struct AlertInfo: Identifiable {
        let title: LocalizedStringKey
        let message: LocalizedStringKey
        var id: String { "\(title)" }
    }

    private var node: MeshNode? { store.nodes[nodeId] }
    private var num: UInt32? { NodeID.num(nodeId) }
    private var isMe: Bool { num != nil && num == radio.myNodeNum }

    var body: some View {
        Group {
            if let node {
                List {
                    header(node)
                    nodeSection(node)
                    metricsSection(node)
                    positionSection(node)
                    if radio.isConnected, let num {
                        actionsSection(node, num: num)
                        traceRouteSection(num: num)
                    }
                }
            } else {
                ContentUnavailableView("Нода не найдена", systemImage: "questionmark.circle")
            }
        }
        .navigationTitle(node?.shortName ?? nodeId)
        .navigationBarTitleDisplayMode(.inline)
        .task { _ = await store.publicKey(for: nodeId) }
        .alert(item: $alert) { info in
            Alert(title: Text(info.title), message: Text(info.message))
        }
    }

    // MARK: - Шапка

    private func header(_ node: MeshNode) -> some View {
        Section {
            HStack(spacing: 14) {
                NodeAvatar(nodeId: node.id, shortName: node.shortName, size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(node.displayName).font(.title3.bold())
                        if node.isFavorite {
                            Image(systemName: "star.fill").foregroundStyle(.yellow)
                        }
                        if node.isIgnored {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }
                    }
                    if let hw = node.hwModel, let name = HardwareCatalog.displayName(hwModel: hw) {
                        Text(name).font(.subheadline).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        if node.sources.contains(.radio) {
                            Label("Радио", systemImage: "dot.radiowaves.up.forward").foregroundStyle(.green)
                        }
                        if node.sources.contains(.mirror) {
                            Label("Зеркало", systemImage: "globe").foregroundStyle(.blue)
                        }
                    }
                    .font(.caption)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Нода

    private func nodeSection(_ node: MeshNode) -> some View {
        Section("Node") {
            if let snr = node.snr, node.hopsAway == 0 {
                LabeledContent("SNR", value: String(format: "%.2f dB", snr))
            }
            LabeledContent("User Id") {
                Text(node.id).textSelection(.enabled)
            }
            if let num {
                LabeledContent("Node Number") {
                    Text(String(num)).textSelection(.enabled)
                }
            }
            if let role = node.role {
                LabeledContent("Role") {
                    Label(role.title, systemImage: role.symbol)
                }
            }
            if let hops = node.hopsAway {
                LabeledContent("Hops Away", value: hops == 0 ? String(localized: "Direct") : "\(hops)")
            }
            if node.viaMqtt {
                LabeledContent("MQTT", value: "✓")
            }
            if let preset = node.modemPreset {
                LabeledContent("Пресет", value: preset)
            }
            if node.sources.contains(.radio) {
                LabeledContent("Public Key") {
                    Image(systemName: node.hasPublicKey ? "key.fill" : "key.slash")
                        .foregroundStyle(node.hasPublicKey ? .green : .orange)
                }
            }
            if node.isUnmessagable {
                LabeledContent("Messaging", value: String(localized: "Unmonitored"))
            }
            if let heard = node.lastHeard {
                LabeledContent("Last heard") {
                    Text(heard, format: .relative(presentation: .named))
                }
            }
        }
    }

    @ViewBuilder
    private func metricsSection(_ node: MeshNode) -> some View {
        if node.batteryLevel != nil || node.voltage != nil || node.channelUtilization != nil || node.uptime != nil {
            Section("Device Metrics") {
                if let battery = node.batteryLevel {
                    LabeledContent("Battery Level", value: battery > 100 ? "PWD" : "\(battery)%")
                }
                if let voltage = node.voltage {
                    LabeledContent("Voltage", value: String(format: "%.2f V", voltage))
                }
                if let util = node.channelUtilization {
                    LabeledContent("Channel Utilization", value: String(format: "%.1f%%", util))
                }
                if let air = node.airUtilTx {
                    LabeledContent("Airtime", value: String(format: "%.1f%%", air))
                }
                if let uptime = node.uptime {
                    LabeledContent("Uptime", value: Duration.seconds(uptime).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated)))
                }
            }
        }
    }

    @ViewBuilder
    private func positionSection(_ node: MeshNode) -> some View {
        if let lat = node.latitude, let lon = node.longitude {
            let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            Section("Position") {
                Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 3000, longitudinalMeters: 3000))) {
                    Marker(node.shortName ?? node.id, coordinate: coordinate)
                }
                .frame(height: 200)
                .listRowInsets(EdgeInsets())
                LabeledContent("Координаты", value: String(format: "%.5f, %.5f", lat, lon))
                if let alt = node.altitude {
                    LabeledContent("Altitude", value: "\(alt) m")
                }
                Button {
                    let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
                    item.name = node.displayName
                    item.openInMaps()
                } label: {
                    Label("Открыть в Картах", systemImage: "map")
                }
            }
        }
    }

    // MARK: - Действия

    private func actionsSection(_ node: MeshNode, num: UInt32) -> some View {
        Section("Actions") {
            Button {
                if radio.deviceConfig?.role == .clientBase && !node.isFavorite {
                    confirmClientBaseFavorite = true
                } else {
                    run { try await radio.setFavorite(num, !node.isFavorite) }
                }
            } label: {
                Label {
                    Text(node.isFavorite ? "Remove from favorites" : "Add to favorites")
                } icon: {
                    Image(systemName: node.isFavorite ? "star.fill" : "star")
                        .symbolRenderingMode(.multicolor)
                }
            }
            .confirmationDialog("Are you sure?", isPresented: $confirmClientBaseFavorite, titleVisibility: .visible) {
                Button("Yes, I control this node") { run { try await radio.setFavorite(num, true) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Client Base should only favorite other nodes you control. Improper use will hurt your local mesh.")
            }

            if !isMe {
                if !node.isUnmessagable {
                    Button {
                        router.openConversation(with: num)
                    } label: {
                        Label("Message", systemImage: "message")
                    }
                }

                Button {
                    run(onSuccess: AlertInfo(title: "User Info Sent",
                                             message: "Your user info has been sent with a request for a response with their user info."),
                        onFailure: AlertInfo(title: "User Info Exchange Failed", message: "Failed to exchange user info.")) {
                        try await radio.exchangeUserInfo(with: num, channel: node.channel)
                    }
                } label: {
                    Label {
                        Text("Exchange User Info")
                    } icon: {
                        Image(systemName: "person.2.badge.gearshape").symbolRenderingMode(.hierarchical)
                    }
                }

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = traceRouteCooldownUntil.map { $0.timeIntervalSince(context.date) } ?? 0
                    Button {
                        traceRouteCooldownUntil = .now.addingTimeInterval(30)
                        run(onSuccess: AlertInfo(title: "Trace Route Sent",
                                                 message: "This could take a while, response will appear in the trace route log for the node it was sent to.")) {
                            try await radio.sendTraceRoute(to: num)
                        }
                    } label: {
                        if remaining > 0 {
                            Label {
                                Text("Trace Route (in \(String(Int(remaining.rounded(.up))))s)")
                            } icon: {
                                Image(systemName: "hourglass")
                            }
                            .foregroundStyle(.secondary)
                        } else {
                            Label {
                                Text("Trace Route")
                            } icon: {
                                Image(systemName: "signpost.right.and.left").symbolRenderingMode(.hierarchical)
                            }
                        }
                    }
                    .disabled(remaining > 0)
                }

                Button(role: .destructive) {
                    run { try await radio.setIgnored(num, !node.isIgnored) }
                } label: {
                    Label {
                        Text(node.isIgnored ? "Remove from ignored" : "Ignore")
                    } icon: {
                        Image(systemName: node.isIgnored ? "minus.circle.fill" : "minus.circle")
                            .symbolRenderingMode(.multicolor)
                    }
                }

                if node.sources.contains(.radio) {
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label {
                            Text("Delete Node")
                        } icon: {
                            Image(systemName: "trash").symbolRenderingMode(.multicolor)
                        }
                    }
                    .confirmationDialog("Are you sure?", isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("Delete Node", role: .destructive) {
                            run {
                                try await radio.removeNode(num)
                                dismiss()
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Traceroute

    @ViewBuilder
    private func traceRouteSection(num: UInt32) -> some View {
        if let result = radio.traceRoutes[num] {
            Section {
                routeView(from: radio.myNodeNum ?? 0, hops: result.towards, snr: result.snrTowards, to: num)
                if result.hasBack {
                    routeView(from: num, hops: result.back, snr: result.snrBack, to: radio.myNodeNum ?? 0)
                }
            } header: {
                Text("Trace Route")
            } footer: {
                Text(result.date, format: .dateTime.hour().minute().second())
            }
        }
    }

    /// Маршрут: отправитель → промежуточные → получатель, SNR на каждом прыжке (в четвертях дБ).
    private func routeView(from: UInt32, hops: [UInt32], snr: [Int32], to: UInt32) -> some View {
        let path = [from] + hops + [to]
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(path.enumerated()), id: \.offset) { index, hop in
                HStack(spacing: 8) {
                    Image(systemName: index == 0 ? "circle.fill" : "arrow.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(name(for: hop))
                    Spacer()
                    if index > 0 {
                        Text(snrText(snr, index - 1))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func name(for num: UInt32) -> String {
        if num == UInt32.max { return "Repeater" }
        let id = NodeID.string(num)
        return store.nodes[id]?.displayName ?? id
    }

    private func snrText(_ snr: [Int32], _ index: Int) -> String {
        guard index < snr.count, snr[index] != -128 else { return "? dB" }
        return String(format: "%.2f dB", Double(snr[index]) / 4)
    }

    private func run(onSuccess: AlertInfo? = nil, onFailure: AlertInfo? = nil, _ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
                if let onSuccess { alert = onSuccess }
            } catch {
                alert = onFailure ?? AlertInfo(title: "Error", message: LocalizedStringKey(error.localizedDescription))
            }
        }
    }
}
