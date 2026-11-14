//
//  HTMLEntities.swift
//  Ergo
//
//  Created by Adon Omeri on 8/11/2026.
//

import Foundation

// MARK: - Entities

enum HTMLEntities {
	static let named: [Substring: String] = [
		"amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
		"ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
		"laquo": "«", "raquo": "»", "middot": "·", "bull": "•", "copy": "©", "reg": "®", "trade": "™", "shy": "",
	]

	/// `&amp;`, `&#39;` and `&#x27;` as characters. Anything it doesn't know stays as written.
	static func decoded(_ text: String) -> String {
		guard text.contains("&") else { return text }

		var result = ""
		var rest = text[...]
		while let ampersand = rest.firstIndex(of: "&") {
			result += rest[..<ampersand]
			let after = rest[rest.index(after: ampersand)...]
			if let semicolon = after.prefix(10).firstIndex(of: ";"), let character = character(for: after[..<semicolon]) {
				result += character
				rest = after[after.index(after: semicolon)...]
			} else {
				result += "&"
				rest = after
			}
		}
		return result + rest
	}

	static func character(for entity: Substring) -> String? {
		guard entity.first == "#" else { return named[entity] }

		let number = entity.dropFirst()
		let code = if number.first == "x" || number.first == "X" {
			UInt32(number.dropFirst(), radix: 16)
		} else {
			UInt32(number)
		}
		return code.flatMap(Unicode.Scalar.init).map { String($0) }
	}
}
