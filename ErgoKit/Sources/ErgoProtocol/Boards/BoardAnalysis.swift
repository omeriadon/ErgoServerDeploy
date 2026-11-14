//
//  BoardAnalysis.swift
//  ErgoKit
//
//  Created by Adon Omeri on 8/11/2026.
//

import Foundation

// MARK: - Request

/// A whole board to read: its cards, arrows and sources, as the person sees them. A link source's page is read on the
/// device first, so `Source.text` is all of what there is to say about it. POSTed to `Path.boardAnalysis`.
public struct BoardAnalysisRequest: Codable, Sendable, Hashable {
	public static let characterLimit = 200_000

	public struct Statement: Codable, Sendable, Hashable {
		public let id: UUID
		public let english: String

		public init(id: UUID, english: String) {
			self.id = id
			self.english = english
		}
	}

	/// An arrow: the premise is a premise of the conclusion
	public struct Link: Codable, Sendable, Hashable {
		public let id: UUID
		public let premise: UUID
		public let conclusion: UUID

		public init(id: UUID, premise: UUID, conclusion: UUID) {
			self.id = id
			self.premise = premise
			self.conclusion = conclusion
		}
	}

	public struct Source: Codable, Sendable, Hashable {
		public let id: UUID
		public let title: String
		public let text: String

		public init(id: UUID, title: String, text: String) {
			self.id = id
			self.title = title
			self.text = text
		}
	}

	public let run: UUID
	public let provider: Provider
	public let statements: [Statement]
	public let links: [Link]
	public let sources: [Source]

	/// What the person asked of the agent, like how concise to be. See `AgentInstructions`.
	public let instructions: String?

	public init(run: UUID, provider: Provider, statements: [Statement], links: [Link], sources: [Source], instructions: String? = nil) {
		self.run = run
		self.provider = provider
		self.statements = statements
		self.links = links
		self.sources = sources
		self.instructions = AgentInstructions.normalized(instructions)
	}

	/// What's wrong with it, worded like a compiler diagnostic. Nil when it can be run.
	public var problem: String? {
		guard !statements.isEmpty || !sources.isEmpty else {
			return "Expected a board with at least one statement or source"
		}
		let ids = statements.map(\.id) + links.map(\.id) + sources.map(\.id)
		guard Set(ids).count == ids.count else {
			return "Expected every statement, link and source to have its own id"
		}
		let characters = statements.reduce(0) { $0 + $1.english.count } + sources.reduce(0) { $0 + $1.title.count + $1.text.count }
		guard characters <= Self.characterLimit else {
			return "Expected a board of at most \(Self.characterLimit) characters, found \(characters)"
		}
		let known = Set(statements.map(\.id))
		guard links.allSatisfy({ known.contains($0.premise) && known.contains($0.conclusion) }) else {
			return "Expected every link to join statements that are in the request"
		}
		return AgentInstructions.problem(instructions)
	}
}

// MARK: - Quotes

/// Quotes are compared ignoring case, runs of whitespace, and curly versus straight quotes
public enum BoardQuote {
	/// The text as compared: folded, with whitespace runs as one space and none at either end
	public static func normalized(_ text: String) -> String {
		String(trimmed(folded(text)).characters)
	}

	public static func isQuote(_ quote: String, in text: String) -> Bool {
		range(of: quote, in: text) != nil
	}

	/// Where it is in `text`, for highlighting. Nil when it isn't there, or the quote is only whitespace.
	public static func range(of quote: String, in text: String) -> Range<String.Index>? {
		let needle = trimmed(folded(quote)).characters
		guard let first = needle.first else { return nil }
		let haystack = folded(text)
		let last = haystack.characters.count - needle.count
		guard last >= 0 else { return nil }

		for start in 0 ... last where haystack.characters[start] == first {
			if haystack.characters[start ..< start + needle.count].elementsEqual(needle) {
				return haystack.ranges[start].lowerBound ..< haystack.ranges[start + needle.count - 1].upperBound
			}
		}
		return nil
	}

	/// Each folded character with where it came from in the original, since folding can change how many there are
	private struct Folded {
		var characters: [Character] = []
		var ranges: [Range<String.Index>] = []
	}

	private static func folded(_ text: String) -> Folded {
		var result = Folded()
		var index = text.startIndex
		while index < text.endIndex {
			var end = text.index(after: index)
			let character = text[index]
			if character.isWhitespace {
				while end < text.endIndex, text[end].isWhitespace {
					end = text.index(after: end)
				}
				result.characters.append(" ")
				result.ranges.append(index ..< end)
			} else {
				for folded in fold(character) {
					result.characters.append(folded)
					result.ranges.append(index ..< end)
				}
			}
			index = end
		}
		return result
	}

	private static func fold(_ character: Character) -> [Character] {
		switch character {
			case "‘", "’", "‚", "‛":
				["'"]
			case "“", "”", "„", "‟":
				["\""]
			default:
				Array(String(character).lowercased())
		}
	}

	private static func trimmed(_ folded: Folded) -> Folded {
		var start = 0
		var end = folded.characters.count
		while start < end, folded.characters[start] == " " {
			start += 1
		}
		while end > start, folded.characters[end - 1] == " " {
			end -= 1
		}
		return Folded(characters: Array(folded.characters[start ..< end]), ranges: Array(folded.ranges[start ..< end]))
	}
}
