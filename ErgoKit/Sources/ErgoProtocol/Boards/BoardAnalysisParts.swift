//
//  BoardAnalysisParts.swift
//  ErgoKit
//
//  Created by Adon Omeri on 14/11/2026.
//

import ErgoTranslation
import Foundation

// A long source is analysed in parts, one after another in the same run, so each part gets the attention a short one
// would. Only the server splits: what the app sends and what it's sent back don't change.

/// One model call of a board's analysis
public struct BoardAnalysisPass: Sendable, Hashable {
	/// What this call may report on, and what its quotes are checked against. The first pass is the whole board with each
	/// long source's first part. Later ones are only the next part of each source that has one, so cards and arrows are
	/// annotated and assessed once.
	public let request: BoardAnalysisRequest

	/// Counted from 1
	public let number: Int
	public let count: Int

	/// Source id -> how many parts it has, for each source in this pass that's in more than one
	public let parts: [UUID: Int]

	public var isFirst: Bool {
		number == 1
	}
}

public extension BoardAnalysisRequest {
	/// The most of one source a single pass reads, the same as Break Down's limit
	static let partLimit = EnglishValidator.characterLimit

	/// The passes that analyse it, in order. A board whose sources all fit is one pass of itself.
	func passes(partLimit: Int = Self.partLimit) -> [BoardAnalysisPass] {
		let split = sources.map { source in
			// Break Down's own cuts, at paragraphs then sentences. A part's whitespace can differ from the source's, which
			// `BoardQuote` ignores, so a quote found in a part is found in the whole text.
			let parts = TextParts.split(source.text, characterLimit: partLimit)
			return (source: source, parts: parts.isEmpty ? [source.text] : parts)
		}
		let count = split.map(\.parts.count).max() ?? 1
		guard count > 1 else {
			return [BoardAnalysisPass(request: self, number: 1, count: 1, parts: [:])]
		}

		return (0 ..< count).map { index in
			let here = split.filter { index < $0.parts.count }
			let request = BoardAnalysisRequest(
				run: run,
				provider: provider,
				statements: index == 0 ? statements : [],
				links: index == 0 ? links : [],
				// The title is the source's own, since a link source's annotations are kept current by it
				sources: here.map { Source(id: $0.source.id, title: $0.source.title, text: $0.parts[index]) },
				instructions: instructions
			)
			let parts = Dictionary(uniqueKeysWithValues: here.filter { $0.parts.count > 1 }.map { ($0.source.id, $0.parts.count) })
			return BoardAnalysisPass(request: request, number: index + 1, count: count, parts: parts)
		}
	}
}
