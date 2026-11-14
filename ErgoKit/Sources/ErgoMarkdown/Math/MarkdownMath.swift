//
//  MarkdownMath.swift
//  ErgoKit
//
//  Created by Adon Omeri on 7/11/2026.
//

import Foundation

/// Marks text as math in an `AttributedString`. The value is where it sits: 0 on the line, 1 raised, -1 lowered.
public enum MarkdownMathAttribute: AttributedStringKey {
	public typealias Value = Int
	public static let name = "ergo.math"
}

// MARK: - Finding maths in markdown

/// Takes the maths out of markdown before it's parsed, since the parser would read a `_` or `*` in it as emphasis and
/// strip its backslashes. Each piece is left behind as a placeholder of private-use characters, for putting back after.
struct MarkdownMathExtraction {
	struct Piece {
		let source: String
		let isDisplay: Bool
	}

	static let open: Character = "\u{E000}"
	static let close: Character = "\u{E001}"

	private(set) var markdown = ""
	private(set) var pieces: [Piece] = []

	static func placeholder(_ index: Int) -> String {
		"\(open)\(index)\(close)"
	}

	init(_ source: String) {
		let characters = Array(source)
		var index = 0
		var atLineStart = true
		var inFence = false

		func matches(_ text: String, at position: Int) -> Bool {
			let wanted = Array(text)
			guard position + wanted.count <= characters.count else { return false }
			return Array(characters[position ..< position + wanted.count]) == wanted
		}

		func find(_ text: String, from position: Int) -> Int? {
			var position = position
			while position < characters.count {
				if characters[position] == "\\", text != "\\]", text != "\\)" {
					position += 2
					continue
				}
				if matches(text, at: position) {
					return position
				}
				position += 1
			}
			return nil
		}

		while index < characters.count {
			let character = characters[index]

			// A fence is left alone until it closes, code isn't maths
			if atLineStart {
				var start = index
				while start < characters.count, characters[start] == " " {
					start += 1
				}
				if matches("```", at: start) {
					inFence.toggle()
				}
			}
			atLineStart = character.isNewline

			if inFence {
				markdown.append(character)
				index += 1
				continue
			}

			switch character {
				case "`":
					// So is a code span
					var ticks = 0
					while index + ticks < characters.count, characters[index + ticks] == "`" {
						ticks += 1
					}
					let fence = String(repeating: "`", count: ticks)
					var end = index + ticks
					while end < characters.count, !matches(fence, at: end) {
						end += 1
					}
					let stop = min(end + ticks, characters.count)
					markdown.append(String(characters[index ..< stop]))
					index = stop

				case "$" where matches("$$", at: index):
					// Still being written counts, so it doesn't flash as raw LaTeX until the closing $$ arrives
					let end = find("$$", from: index + 2)
					add(String(characters[(index + 2) ..< (end ?? characters.count)]), isDisplay: true)
					index = end.map { $0 + 2 } ?? characters.count

				case "$":
					if let end = Self.inlineEnd(in: characters, from: index) {
						add(String(characters[(index + 1) ..< end]), isDisplay: false)
						index = end + 1
					} else {
						markdown.append(character)
						index += 1
					}

				case "\\" where matches("\\[", at: index):
					let end = find("\\]", from: index + 2)
					add(String(characters[(index + 2) ..< (end ?? characters.count)]), isDisplay: true)
					index = end.map { $0 + 2 } ?? characters.count

				case "\\" where matches("\\(", at: index):
					if let end = find("\\)", from: index + 2) {
						add(String(characters[(index + 2) ..< end]), isDisplay: false)
						index = end + 2
					} else {
						markdown.append(character)
						index += 1
					}

				case "\\":
					// An escape, like \$, which the parser deals with
					markdown.append(String(characters[index ..< min(index + 2, characters.count)]))
					index += 2

				default:
					markdown.append(character)
					index += 1
			}
		}
	}

	private mutating func add(_ source: String, isDisplay: Bool) {
		markdown += Self.placeholder(pieces.count)
		pieces.append(Piece(source: source, isDisplay: isDisplay))
	}

	/// A `$` only opens maths when words don't sit against it the way a price does: not followed by a space, closed on
	/// the same line by a `$` not after a space, and that not followed by a digit. So "$5 and $10" stays as it is.
	static func inlineEnd(in characters: [Character], from start: Int) -> Int? {
		let first = start + 1
		guard first < characters.count, !characters[first].isWhitespace else { return nil }

		var index = first
		while index < characters.count {
			let character = characters[index]
			if character.isNewline {
				return nil
			}
			if character == "\\" {
				index += 2
				continue
			}
			if character == "$" {
				guard !characters[index - 1].isWhitespace, index > first else { return nil }
				if index + 1 < characters.count, characters[index + 1].isNumber {
					return nil
				}
				return index
			}
			index += 1
		}
		return nil
	}

	/// The placeholders in `text` swapped back for their maths. It reads only the placeholders `text` holds, since a long
	/// answer has a piece of maths in most of its blocks and trying each piece on each block grows with the square.
	func restored(_ text: AttributedString) -> AttributedString {
		guard !pieces.isEmpty else { return text }
		var result = AttributedString()
		var rest = text[text.startIndex ..< text.endIndex]
		while let open = rest.characters.firstIndex(of: Self.open) {
			let after = rest.characters.index(after: open)
			guard
				let close = rest.characters[after...].firstIndex(of: Self.close),
				let index = Int(String(rest.characters[after ..< close])),
				pieces.indices.contains(index)
			else {
				// Not one of ours, so it's kept as written
				result += AttributedString(rest[rest.startIndex ..< after])
				rest = rest[after ..< rest.endIndex]
				continue
			}
			result += AttributedString(rest[rest.startIndex ..< open])
			result += LaTeX.attributed(pieces[index].source)
			rest = rest[rest.characters.index(after: close) ..< rest.endIndex]
		}
		result += AttributedString(rest)
		return result
	}

	/// The maths a paragraph holds, when that's all it holds and it's meant to stand on its own line
	func display(in text: AttributedString) -> AttributedString? {
		let plain = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
		guard
			plain.first == Self.open, plain.last == Self.close,
			let index = Int(plain.dropFirst().dropLast()),
			pieces.indices.contains(index), pieces[index].isDisplay
		else {
			return nil
		}
		return LaTeX.attributed(pieces[index].source)
	}
}
