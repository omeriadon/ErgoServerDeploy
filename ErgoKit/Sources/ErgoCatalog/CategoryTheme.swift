//
//  CategoryTheme.swift
//  ErgoKit
//
//  Created by Adon Omeri on 8/11/2026.
//

#if canImport(SwiftUI)
	import SwiftUI
#endif

/// The colour each library category is shown in. It lives here, not in the JSON, so the files stay content only,
/// and the app and the widget get the same colour from one place.
public enum CategoryTheme: String, Sendable, CaseIterable {
	case red
	case green
	case blue
	case orange
	case mint
	case purple
	case yellow
	case teal

	/// The theme of a category such as `"biases"`. Nil for a name that isn't one of `LibraryCatalog.categories`.
	public static func of(_ category: String) -> CategoryTheme? {
		switch category {
			case "biases":
				.red
			case "concepts":
				.green
			case "fallacies":
				.blue
			case "symbols":
				.orange
			case "paradoxes":
				.mint
			case "philosophers":
				.purple
			case "razors":
				.yellow
			case "arguments":
				.teal
			default:
				nil
		}
	}

	#if canImport(SwiftUI)
		/// The colour of a category given as an enum with a string raw value, such as the app's `LibraryContent`.
		/// Blue for one that has no theme.
		public static func color(for category: some RawRepresentable<String>) -> Color {
			(of(category.rawValue) ?? .blue).color
		}

		public var color: Color {
			switch self {
				case .red:
					.red
				case .green:
					.green
				case .blue:
					.blue
				case .orange:
					.orange
				case .mint:
					.mint
				case .purple:
					.purple
				case .yellow:
					.yellow
				case .teal:
					.teal
			}
		}
	#endif
}
