import Foundation

extension String {
	// Filter out variation selectors from the string
	var withoutVariationSelectors: String {
		var scalars: [UnicodeScalar] = []
		var previousWasASCII = false

		for scalar in self.unicodeScalars {
			if scalar.properties.isVariationSelector {
				// Only keep variation selector if the previous character was ASCII
				if previousWasASCII {
					scalars.append(scalar)
				}
				// No need to update previousWasASCII since variation selectors aren't characters
				// Shouldn't have 2 in a row
			} else {
				scalars.append(scalar)
				previousWasASCII = scalar.isASCII
			}
		}

		return scalars.compactMap { UnicodeScalar($0) }
			.map { String($0) }
			.joined()
	}
}
