//
//  TextParts.swift
//  ErgoKit
//
//  Created by Adon Omeri on 10/11/2026.
//

import Foundation

/// Cuts a long text into parts small enough to break down, keeping every word. It cuts at paragraphs, then sentences, so a
/// claim isn't split in half, and only a single sentence longer than the limit gets cut mid-way.
public enum TextParts {
	/// How many parts one text can become
	public static let limit = 40

	public static func split(_ text: String, characterLimit: Int = EnglishValidator.characterLimit) -> [String] {
		var parts: [String] = []
		var current = ""

		func flush() {
			let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
			if !trimmed.isEmpty {
				parts.append(trimmed)
			}
			current = ""
		}

		func add(_ piece: String, separator: String) {
			if !current.isEmpty, current.count + separator.count + piece.count > characterLimit {
				flush()
			}
			current += current.isEmpty ? piece : separator + piece
		}

		for paragraph in text.components(separatedBy: "\n\n").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !paragraph.isEmpty {
			if paragraph.count <= characterLimit {
				add(paragraph, separator: "\n\n")
				continue
			}
			for sentence in sentences(in: paragraph) {
				if sentence.count <= characterLimit {
					add(sentence, separator: " ")
				} else {
					flush()
					var rest = Substring(sentence)
					while !rest.isEmpty {
						// A cut can land on nothing but spaces, and an empty part is nothing to break down
						let piece = rest.prefix(characterLimit).trimmingCharacters(in: .whitespacesAndNewlines)
						if !piece.isEmpty {
							parts.append(piece)
						}
						rest = rest.dropFirst(characterLimit)
					}
				}
			}
		}
		flush()
		return parts
	}

	private static func sentences(in paragraph: String) -> [String] {
		var found: [String] = []
		var start = paragraph.startIndex
		for index in paragraph.indices where ".?!".contains(paragraph[index]) {
			let next = paragraph.index(after: index)
			guard next < paragraph.endIndex, paragraph[next].isWhitespace else { continue }
			found.append(paragraph[start ... index].trimmingCharacters(in: .whitespacesAndNewlines))
			start = next
		}
		let rest = paragraph[start...].trimmingCharacters(in: .whitespacesAndNewlines)
		if !rest.isEmpty {
			found.append(rest)
		}
		return found
	}
}
