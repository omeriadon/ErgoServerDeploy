//
//  BoardAnalysisShown.swift
//  ErgoKit
//
//  Created by Adon Omeri on 8/11/2026.
//

import ErgoSync
import Foundation

// What's shown of a board's analysis is worked out each time from what's on the board now, and never stored.

/// The board as the analysis sees it, in plain values, so the app's own types can feed it without ErgoKit knowing them
public struct BoardAnalysisSnapshot: Sendable, Hashable {
	public struct Link: Sendable, Hashable {
		public let id: UUID
		public let premise: UUID
		public let conclusion: UUID

		public init(id: UUID, premise: UUID, conclusion: UUID) {
			self.id = id
			self.premise = premise
			self.conclusion = conclusion
		}
	}

	public struct Source: Sendable, Hashable {
		public let id: UUID
		public let title: String

		/// Nil for a link, whose page text isn't kept
		public let text: String?

		public init(id: UUID, title: String, text: String?) {
			self.id = id
			self.title = title
			self.text = text
		}
	}

	/// Statement id -> English
	public let statements: [UUID: String]
	public let links: [Link]
	public let sources: [Source]

	public init(statements: [UUID: String], links: [Link], sources: [Source]) {
		self.statements = statements
		self.links = links
		self.sources = sources
	}
}

/// An annotation with the stamp of the record it came in, which is what says which run is newest
public struct WrittenAnnotation: Sendable, Hashable {
	public let annotation: BoardAnnotation
	public let stamp: SyncStamp

	public init(annotation: BoardAnnotation, stamp: SyncStamp) {
		self.annotation = annotation
		self.stamp = stamp
	}

	/// Nil for another kind, a tombstone, or what this version can't read
	public init?(_ record: SyncRecord) {
		guard let annotation = BoardAnnotation(record), let stamp = record.newestStamp else { return nil }
		self.init(annotation: annotation, stamp: stamp)
	}
}

public struct BoardAnalysisShown: Sendable, Hashable {
	/// Only the newest run's of each target and entry, and only while still true of the board. Oldest first.
	public let current: [BoardAnnotation]

	/// Newest run's, but the board has changed under them
	public let stale: [BoardAnnotation]

	/// Whether the sheet says the board has changed and offers to run again
	public var hasStale: Bool {
		!stale.isEmpty
	}

	public init(_ written: [WrittenAnnotation], on board: BoardAnalysisSnapshot) {
		let newest = Self.newestRun(written)
		current = newest.filter { Self.isCurrent($0, on: board) }
		stale = newest.filter { !Self.isCurrent($0, on: board) }
	}

	/// Of the same target and entry (an assessment counting separately from a quote), only the newest run's
	public static func newestRun(_ written: [WrittenAnnotation]) -> [BoardAnnotation] {
		struct Group: Hashable {
			let target: BoardAnalysisTarget
			let category: String
			let id: String
			let assessed: Bool
		}
		let groups = Dictionary(grouping: written) { item in
			Group(target: item.annotation.target, category: item.annotation.citation.category, id: item.annotation.citation.id, assessed: item.annotation.assessment != nil)
		}
		let kept = groups.values.flatMap { items in
			let newest = items.max { ($0.stamp, $0.annotation.id.uuidString) < ($1.stamp, $1.annotation.id.uuidString) }
			return items.filter { $0.annotation.run == newest?.annotation.run }
		}
		return kept.sorted { ($0.stamp, $0.annotation.id.uuidString) < ($1.stamp, $1.annotation.id.uuidString) }.map(\.annotation)
	}

	/// Whether what the annotation says still holds of the board
	public static func isCurrent(_ annotation: BoardAnnotation, on board: BoardAnalysisSnapshot) -> Bool {
		switch (annotation.assessment, annotation.target) {
			case let (.arrow?, .link(id)):
				guard let link = board.links.first(where: { $0.id == id }) else { return false }
				return isAssessmentCurrent(annotation, conclusion: link.conclusion, on: board)

			case let (.conclusion?, .statement(id)):
				return isAssessmentCurrent(annotation, conclusion: id, on: board)

			case (.some, _):
				return false

			case let (nil, .statement(id)):
				return board.statements[id].map { quoted(annotation, in: [$0]) } ?? false

			case let (nil, .link(id)):
				guard let link = board.links.first(where: { $0.id == id }) else { return false }
				return quoted(annotation, in: [board.statements[link.premise], board.statements[link.conclusion]].compactMap(\.self))

			case let (nil, .source(id)):
				guard let source = board.sources.first(where: { $0.id == id }) else { return false }
				guard let text = source.text else { return annotation.basis[id] == source.title }
				return quoted(annotation, in: [text])
		}
	}

	private static func quoted(_ annotation: BoardAnnotation, in texts: [String]) -> Bool {
		guard let quote = annotation.quote else { return false }
		return texts.contains { BoardQuote.isQuote(quote, in: $0) }
	}

	/// The conclusion and its premises are all as they were judged, and no premise has come or gone
	private static func isAssessmentCurrent(_ annotation: BoardAnnotation, conclusion: UUID, on board: BoardAnalysisSnapshot) -> Bool {
		let premises = Set(board.links.filter { $0.conclusion == conclusion }.map(\.premise))
		guard !premises.isEmpty, board.statements[conclusion] != nil, Set(annotation.basis.keys) == premises.union([conclusion]) else {
			return false
		}
		return annotation.basis.allSatisfy { board.statements[$0.key] == $0.value }
	}
}

// MARK: - On the canvas

/// The short version of a finding, for the comment box beside what it's about
public struct BoardAnalysisComment: Sendable, Hashable {
	/// The entry it cites
	public let title: String

	/// One of the few findings that matter most
	public let isKey: Bool

	/// The annotation's first sentence, as plain text
	public let text: String

	public init(_ annotation: BoardAnnotation) {
		title = annotation.citation.name
		isKey = annotation.isKey
		text = Self.firstSentence(ofMarkdown: annotation.markdown)
	}

	private static let characterLimit = 160
	private static let abbreviations = ["e.g", "i.e", "cf", "vs", "etc"]

	/// Reports open with their point, so the first sentence is what a comment box has room for
	public static func firstSentence(ofMarkdown markdown: String) -> String {
		let plain = markdown
			.replacing(#/\[([^\]]*)\]\([^)]*\)/#) { String($0.1) }
			.replacing(#/[*_`$]/#, with: "")
		let paragraph = plain.components(separatedBy: "\n\n")
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.first { !$0.isEmpty } ?? ""
		let line = paragraph.split(whereSeparator: \.isNewline).joined(separator: " ")
		let sentence = firstSentence(of: line)
		return sentence.count > characterLimit ? sentence.prefix(characterLimit - 1) + "…" : sentence
	}

	private static func firstSentence(of line: String) -> String {
		for index in line.indices where ".?!".contains(line[index]) {
			let next = line.index(after: index)
			guard next < line.endIndex, line[next].isWhitespace else { continue }
			let lastWord = line[..<index].split(separator: " ").last.map { $0.lowercased() } ?? ""
			if line[index] == ".", abbreviations.contains(lastWord) {
				continue
			}
			return String(line[...index])
		}
		return line
	}
}

public extension BoardAnalysisShown {
	/// One comment for each thing that has something to say: a key finding, else the first, since reports come most
	/// important first, or failing that, why a conclusion isn't well supported.
	var comments: [UUID: BoardAnalysisComment] {
		var comments: [UUID: BoardAnalysisComment] = [:]
		for annotation in current where annotation.assessment == nil && comments[annotation.target.id]?.isKey != true {
			if annotation.isKey || comments[annotation.target.id] == nil {
				comments[annotation.target.id] = BoardAnalysisComment(annotation)
			}
		}
		for annotation in current where comments[annotation.target.id] == nil {
			if case let .conclusion(support)? = annotation.assessment, support != .wellSupported {
				comments[annotation.target.id] = BoardAnalysisComment(annotation)
			}
		}
		return comments
	}
}

// MARK: - Reports

public extension BoardAnalysisStatus {
	/// What to show for the run: a `running` one that's gone too long shows as interrupted, and can be run again
	enum Shown: Sendable, Hashable {
		case running, finished, failed, cancelled, interrupted
	}

	func shown(at now: Date) -> Shown {
		if isInterrupted(at: now) {
			return .interrupted
		}
		switch state {
			case .running:
				return .running
			case .finished:
				return .finished
			case .failed:
				return .failed
			case .cancelled:
				return .cancelled
		}
	}
}
