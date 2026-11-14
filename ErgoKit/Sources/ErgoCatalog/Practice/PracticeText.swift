//
//  PracticeText.swift
//  ErgoKit
//
//  Created by Adon Omeri on 14/11/2026.
//

import Foundation

/// Hiding an entry's name in its own text, so a card never gives its answer away
public enum PracticeText {
	/// What stands in for a hidden name
	public static let blank = "___"

	/// Whether `name` is in `text` as whole words, ignoring case and accents
	public static func mentions(_ name: String, in text: String) -> Bool {
		range(of: name, in: text, from: text.startIndex) != nil
	}

	/// Whether any of `names` is in `text` as whole words
	public static func mentionsAny(_ names: [String], in text: String) -> Bool {
		names.contains { mentions($0, in: text) }
	}

	/// `text` with every whole-word mention of `names` replaced by `blank`. Longer names go first, so an alias inside
	/// the name doesn't leave half of it behind.
	public static func redacting(_ names: [String], in text: String) -> String {
		var result = text
		for name in names.sorted(by: { $0.count > $1.count }) where !name.isEmpty {
			var start = result.startIndex
			while let found = range(of: name, in: result, from: start) {
				result.replaceSubrange(found, with: blank)
				start = result.index(found.lowerBound, offsetBy: blank.count, limitedBy: result.endIndex) ?? result.endIndex
			}
		}
		return result
	}

	/// The first whole-word match at or after `start`
	private static func range(of name: String, in text: String, from start: String.Index) -> Range<String.Index>? {
		guard !name.isEmpty else { return nil }
		var searchStart = start
		while searchStart < text.endIndex,
		      let found = text.range(of: name, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart ..< text.endIndex)
		{
			let before = found.lowerBound == text.startIndex ? nil : text[text.index(before: found.lowerBound)]
			let after = found.upperBound == text.endIndex ? nil : text[found.upperBound]
			if !isWordCharacter(before), !isWordCharacter(after) {
				return found
			}
			searchStart = text.index(after: found.lowerBound)
		}
		return nil
	}

	private static func isWordCharacter(_ character: Character?) -> Bool {
		guard let character else { return false }
		return character.isLetter || character.isNumber
	}
}
