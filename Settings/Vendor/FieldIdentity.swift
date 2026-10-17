import Foundation
/// A protobuf field, named the way the generated registry names it.
///
/// Tag, not Swift property name: a field's spelling differs across its proto,
/// generated, entity and view-state forms — `sx126x_rx_boosted_gain` is
/// `sx126XRxBoostedGain` is `rxBoostedGain` — and only the tag is stable by
/// contract.
struct FieldIdentity: Hashable {
	/// Full proto name, e.g. `meshtastic.Config.LoRaConfig`.
	let messageName: String
	/// Proto field number.
	let tag: Int

	/// The registry entry for this field, or nil if it carries no annotation.
	/// Absence means "nothing was said", never "not deprecated".
	var metadata: FieldMetadata? { FieldMetadataRegistry.get(messageName, tag: tag) }
}

/// The three groupings `Settings.swift` already uses, so a result's breadcrumb
/// matches the list the user would otherwise have scrolled. Declaration order is
/// also the tiebreak order for equally-scored results.
enum SettingsListSection: Int, CaseIterable, Hashable {
	/// The unlabelled group at the top of Settings — About, Help, App Settings,
	/// Local Mesh Discovery, Routes, Route Recorder, Firmware Updates.
	case general
	case radioConfiguration
	case deviceConfiguration
	case configure
	case logging
	case developers

	var title: String {
		switch self {
		case .general:
			// No header on screen; results still need one to group under.
			return String(localized: "General", comment: "Settings list section")
		case .radioConfiguration:
			return String(localized: "Radio Configuration", comment: "Settings list section")
		case .deviceConfiguration:
			return String(localized: "Device Configuration", comment: "Settings list section")
		case .configure:
			return String(localized: "Configure", comment: "Settings list section")
		case .logging:
			return String(localized: "Logging", comment: "Settings list section")
		case .developers:
			return String(localized: "Developers", comment: "Settings list section")
		}
	}
}

/// Why a result is shown the way it is.
///
/// Computed per query from connection and node state, not baked into the index,
/// which stays static. One mechanism covers every reason a result is not plainly
/// available, so nothing disappears without a reason the row can state.
enum SettingsSearchVisibility: Hashable {
	case normal
	/// Shown, de-emphasised, with `reason` explaining why.
	case deEmphasised(reason: String)
	/// Not shown at all.
	case hidden
}

