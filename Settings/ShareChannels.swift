import CoreImage.CIFilterBuiltins
import MeshtasticProtobufs
import SwiftUI

/// Генерация QR-кода с каналами — по ShareChannels.swift из Meshtastic-Apple.
struct QrCodeImage {
    let context = CIContext()

    func generateQRCode(from text: String) -> UIImage {
        var qrImage = UIImage(systemName: "xmark.circle") ?? UIImage()
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        let transform = CGAffineTransform(scaleX: 20, y: 20)
        if let outputImage = filter.outputImage?.transformed(by: transform),
           let image = context.createCGImage(outputImage, from: outputImage.extent) {
            qrImage = UIImage(cgImage: image)
        }
        return qrImage
    }
}

struct ShareChannels: View {
    @Environment(RadioManager.self) private var radio
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var included: Set<Int32> = Set(0..<8)
    @State private var replaceChannels = true
    @State private var channelSet = ChannelSet()
    @State private var channelsUrl = ""
    private let qrCodeImage = QrCodeImage()

    private var shareableChannels: [Channel] {
        radio.channelSlots.filter { (0...7).contains($0.index) && $0.role != .disabled }
    }

    private var channelQRMode: ChannelQRMode { ChannelQRMode(addChannels: !replaceChannels) }
    private var shortName: String { radio.myUser?.shortName ?? "????" }

    var body: some View {
        GeometryReader { bounds in
            let smallest = min(bounds.size.width, bounds.size.height)
            let qrSide = smallest * (horizontalSizeClass == .regular ? 0.6 : 0.75)
            ScrollView {
                if shareableChannels.isEmpty {
                    ContentUnavailableView("No Shareable Channels", systemImage: "qrcode",
                                           description: Text("Connect to a radio with channel settings before sharing."))
                        .padding(.vertical, 24)
                } else {
                    channelSelectionGrid
                    if channelSet.settings.isEmpty {
                        ContentUnavailableView("No Channels Selected", systemImage: "qrcode",
                                               description: Text("Select at least one channel before sharing."))
                            .padding(.vertical, 24)
                    } else if channelsUrl.isEmpty {
                        ContentUnavailableView("Share Link Unavailable", systemImage: "qrcode",
                                               description: Text("Select channels again before sharing."))
                            .padding(.vertical, 24)
                    } else {
                        let qrImage = qrCodeImage.generateQRCode(from: channelsUrl)
                        VStack {
                            Toggle(isOn: $replaceChannels) {
                                Label(channelQRMode.title, systemImage: channelQRMode.symbolName)
                            }
                            .toggleStyle(.button)
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .controlSize(.large)
                            .padding(.vertical)

                            Text(channelQRMode.consequence)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)

                            ShareLink("Share QR Code & Link",
                                      item: Image(uiImage: qrImage),
                                      subject: Text("Meshtastic Node \(shortName) has shared channels with you"),
                                      message: Text(channelsUrl),
                                      preview: SharePreview("Meshtastic Node \(shortName) has shared channels with you",
                                                            image: Image(uiImage: qrImage)))
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                                .controlSize(.large)
                                .padding(.bottom)

                            Image(uiImage: qrImage)
                                .resizable()
                                .interpolation(.none)
                                .scaledToFit()
                                .frame(width: qrSide, height: qrSide)
                        }
                    }
                }
            }
        }
        .navigationTitle("Generate QR Code")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: generateChannelSet)
        .onChange(of: included) { generateChannelSet() }
        .onChange(of: replaceChannels) { generateChannelSet() }
        .onChange(of: radio.channelSlots) { generateChannelSet() }
    }

    private var channelSelectionGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
            GridRow {
                Text("Include").font(.caption).fontWeight(.bold)
                Text("Channel").font(.caption).fontWeight(.bold)
                Text("Encrypted").font(.caption).fontWeight(.bold)
            }
            ForEach(shareableChannels, id: \.index) { channel in
                GridRow {
                    Toggle("Channel \(channel.index) Included", isOn: includeBinding(for: channel.index))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(channel.role == .primary && channel.index != 0)
                    Text(channelDisplayName(channel))
                        .fixedSize(horizontal: false, vertical: true)
                    let encrypted = channel.settings.psk.count > 1
                    Image(systemName: encrypted ? "lock.fill" : "lock.open.fill")
                        .foregroundStyle(encrypted ? .green : .yellow)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal)
    }

    private func includeBinding(for index: Int32) -> Binding<Bool> {
        Binding(
            get: { included.contains(index) },
            set: { if $0 { included.insert(index) } else { included.remove(index) } }
        )
    }

    private func channelDisplayName(_ channel: Channel) -> String {
        if !channel.settings.name.isEmpty { return channel.settings.name }
        return channel.index == 0 ? "Primary" : "Channel \(channel.index)"
    }

    private func generateChannelSet() {
        channelSet = ChannelSet()
        if let lora = radio.loraConfig { channelSet.loraConfig = lora }
        channelSet.settings = shareableChannels.compactMap { channel in
            guard included.contains(channel.index) else { return nil }
            var settings = ChannelSettings()
            settings.name = channel.settings.name
            settings.psk = channel.settings.psk
            settings.id = channel.settings.id
            settings.moduleSettings.positionPrecision = channel.settings.moduleSettings.positionPrecision
            settings.moduleSettings.isMuted = channel.settings.moduleSettings.isMuted
            return settings
        }
        guard !channelSet.settings.isEmpty,
              let url = try? MeshtasticChannelURL.urlString(for: channelSet, addChannels: !replaceChannels) else {
            channelsUrl = ""
            return
        }
        channelsUrl = url
    }
}
