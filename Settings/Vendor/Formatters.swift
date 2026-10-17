import Foundation

var frequencyOverrideFormatter: NumberFormatter {
	let formatter = NumberFormatter()
	formatter.numberStyle = .decimal
	formatter.usesGroupingSeparator = false
	formatter.minimumFractionDigits = 0
	formatter.maximumFractionDigits = 6
	return formatter
}
