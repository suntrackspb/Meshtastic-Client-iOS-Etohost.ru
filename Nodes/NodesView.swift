import SwiftUI

struct NodesView: View {
    @Environment(NodesStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var filter = NodeFilter()
    @State private var search = ""
    @State private var showFilters = false

    var body: some View {
        NavigationStack {
            let items = filter.apply(to: store.nodes.values, search: search)
            List(items) { node in
                NavigationLink {
                    NodeDetailView(nodeId: node.id)
                } label: {
                    NodeRow(node: node)
                }
                    .swipeActions(edge: .trailing) {
                        if let num = NodeID.num(node.id) {
                            Button("Написать", systemImage: "envelope") { router.openConversation(with: num) }
                                .tint(.blue)
                        }
                    }
                    .contextMenu {
                        if let num = NodeID.num(node.id) {
                            Button("Написать", systemImage: "envelope") { router.openConversation(with: num) }
                        }
                        Button("Копировать ID", systemImage: "doc.on.doc") { UIPasteboard.general.string = node.id }
                    }
            }
            .listStyle(.plain)
            .overlay {
                if store.isLoading && store.nodes.isEmpty {
                    ProgressView("Загрузка нод…")
                } else if let error = store.lastError {
                    ContentUnavailableView("Нет данных", systemImage: "wifi.slash", description: Text(error))
                } else if items.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .refreshable { await store.refreshFromMirror() }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Long/short name или !id")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .navigationTitle("Ноды")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("\(items.count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showFilters = true
                    } label: {
                        Image(systemName: filter.activeCount > 0
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("Фильтры")
                }
            }
            .sheet(isPresented: $showFilters) {
                NodeFilterSheet(filter: $filter, presets: store.modemPresets)
                    .presentationDetents([.medium, .large])
            }
        }
    }
}

private struct NodeRow: View {
    let node: MeshNode

    var body: some View {
        HStack(spacing: 12) {
            NodeAvatar(nodeId: node.id, shortName: node.shortName, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(node.displayName).font(.headline).lineLimit(1)
                    if node.isFavorite {
                        Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                    }
                    if node.hasPublicKey {
                        Image(systemName: "key.fill").font(.caption).foregroundStyle(.green)
                            .accessibilityLabel("Public Key")
                    }
                }
                HStack(spacing: 8) {
                    if let role = node.role {
                        Label(role.title, systemImage: role.symbol)
                    }
                    if let preset = node.modemPreset {
                        Text(preset)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(CompactLabelStyle())

                HStack(spacing: 8) {
                    if let heard = node.lastHeard {
                        Text(heard, format: .relative(presentation: .named))
                    }
                    if let hops = node.hopsAway {
                        Label(hops == 0 ? "напрямую" : "\(hops) хоп", systemImage: "arrow.triangle.branch")
                    }
                    if node.hasPosition {
                        Image(systemName: "mappin.and.ellipse")
                    }
                    if let battery = node.batteryLevel {
                        Label("\(min(battery, 100))%", systemImage: "battery.75percent")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .labelStyle(CompactLabelStyle())
            }
            Spacer(minLength: 0)
            VStack(spacing: 4) {
                if node.sources.contains(.radio) {
                    Image(systemName: "dot.radiowaves.up.forward").foregroundStyle(.green)
                }
                if node.sources.contains(.mirror) {
                    Image(systemName: "globe").foregroundStyle(.blue)
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 2)
    }
}

private struct NodeFilterSheet: View {
    @Binding var filter: NodeFilter
    let presets: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Источник") {
                    Picker("Источник", selection: $filter.source) {
                        ForEach(NodeFilter.Source.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Активность") {
                    Picker("Слышна за", selection: $filter.lastHeard) {
                        ForEach(NodeFilter.LastHeard.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Сортировка", selection: $filter.sort) {
                        ForEach(NodeFilter.Sort.allCases) { Text($0.rawValue).tag($0) }
                    }
                }

                Section {
                    Picker("Максимум хопов", selection: $filter.maxHops) {
                        Text("Без ограничения").tag(Int?.none)
                        ForEach(0...7, id: \.self) { Text($0 == 0 ? "Только прямые" : "\($0)").tag(Int?.some($0)) }
                    }
                } header: {
                    Text("Хопы")
                } footer: {
                    Text("Хопы известны только для нод из радиоэфира подключённой ноды.")
                }

                Section("Роли") {
                    ForEach(NodeRole.allCases) { role in
                        Button {
                            if filter.roles.contains(role) { filter.roles.remove(role) } else { filter.roles.insert(role) }
                        } label: {
                            HStack {
                                Label(role.title, systemImage: role.symbol)
                                Spacer()
                                if filter.roles.contains(role) {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .tint(.primary)
                    }
                }

                Section("Прочее") {
                    Picker("Пресет", selection: $filter.modemPreset) {
                        Text("Любой").tag(String?.none)
                        ForEach(presets, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    Toggle("Только с позицией", isOn: $filter.withPositionOnly)
                    Toggle("Только избранные", isOn: $filter.favoritesOnly)
                }

                Section {
                    Button(role: .destructive) {
                        filter = NodeFilter()
                    } label: {
                        Label("Сбросить фильтры", systemImage: "line.3.horizontal.decrease.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(filter == NodeFilter())
                }
            }
            .navigationTitle("Фильтры")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Сбросить") { filter = NodeFilter() }
                        .disabled(filter == NodeFilter())
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}
