//
//  ExternalNotificationConfig.swift
//  Meshtastic
//
//  Copyright(c) Garth Vander Houwen 9/18/26.
//
import SwiftUI
import MeshtasticProtobufs


struct ExternalNotificationConfig: View {
	@EnvironmentObject private var accessoryManager: AccessoryManager
	let node: NodeInfoEntity?

	private typealias F = ModuleConfig.ExternalNotificationConfig.Fields

	static func overlay() -> ConfigFormOverlay<ModuleConfig.ExternalNotificationConfig> {
		.init(sections: [
			.init(title: String(localized: "Options", comment: "Settings section"), fields: [
				.init(F.enabled, symbol: "megaphone"),
				.init(F.alertBell, symbol: "bell"),
				.init(F.alertMessage, symbol: "message"),
				.init(F.usePwm, symbol: "light.beacon.max.fill"),
				.init(F.useI2SAsBuzzer, symbol: "light.beacon.max.fill")
			]),
			.init(title: String(localized: "Primary GPIO", comment: "Settings section"), fields: [
				.init(F.active, symbol: "togglepower"),
				.init(F.output, control: .gpioPin),
				.init(F.outputMs, control: .options(OutputIntervals.allCases.map {
					ConfigFormOption(value: $0.rawValue, title: $0.description)
				})),
				.init(F.nagTimeout, control: .interval(.nagTimeout))
			]),
			.init(title: String(localized: "Optional GPIO", comment: "Settings section"), fields: [
				.init(F.alertBellBuzzer, symbol: "bell"),
				.init(F.alertBellVibra, symbol: "bell"),
				.init(F.alertMessageBuzzer, symbol: "message"),
				.init(F.alertMessageVibra, symbol: "message"),
				.init(F.outputBuzzer, control: .gpioPin),
				.init(F.outputVibra, control: .gpioPin)
			])
		])
	}

	var body: some View {
		MetadataConfigForm(
			node: node, title: "External Notification", overlay: Self.overlay(),
			request: accessoryManager.requestConfig,
			save: { config, from, to in
				_ = try await accessoryManager.saveExternalNotificationModuleConfig(config: config, fromUser: from, toUser: to)
			})
		.navigationTitle("External Notification Config")
	}
}
