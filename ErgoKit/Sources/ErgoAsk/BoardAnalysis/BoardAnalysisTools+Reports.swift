//
//  BoardAnalysisTools+Reports.swift
//  Ergo
//
//  Created by Adon Omeri on 8/11/2026.
//

import ErgoCatalog
import ErgoProtocol
import ErgoSync
import Foundation

extension BoardAnalysisTools {
	// MARK: - Reports

	struct Arguments {
		let values: [String: JSONValue]

		init(_ values: [String: JSONValue]) {
			self.values = values
		}

		func string(_ key: String) throws(AskTools.Failure) -> String {
			guard case let .string(value)? = values[key], !value.isEmpty else {
				throw AskTools.Failure(message: "Expected '\(key)'")
			}
			return value
		}

		/// Empty is the same as left out
		func optionalString(_ key: String) -> String? {
			guard case let .string(value)? = values[key] else { return nil }
			let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
			return trimmed.isEmpty ? nil : trimmed
		}

		func id(_ key: String) throws(AskTools.Failure) -> UUID {
			let text = try string(key)
			guard let id = UUID(uuidString: text) else {
				throw AskTools.Failure(message: "Expected '\(key)' to be an id from the board, found '\(text)'")
			}
			return id
		}
	}

	func annotate(_ arguments: Arguments) throws(AskTools.Failure) -> AskToolReply<BoardAnalysisEvent> {
		let (kind, id) = try (arguments.string("target_kind"), arguments.id("target_id"))
		let target: BoardAnalysisTarget
		let texts: [String]
		switch kind {
			case "statement":
				guard let statement = request.statements.first(where: { $0.id == id }) else { throw missing("statement", id) }
				target = .statement(id)
				texts = [statement.english]
			case "link":
				guard let link = request.links.first(where: { $0.id == id }) else { throw missing("link", id) }
				target = .link(id)
				texts = request.statements.filter { $0.id == link.premise || $0.id == link.conclusion }.map(\.english)
			case "source":
				guard let source = request.sources.first(where: { $0.id == id }) else { throw missing("source", id) }
				target = .source(id)
				texts = [source.text]
			default:
				throw AskTools.Failure(message: "Expected 'target_kind' to be statement, link or source, found '\(kind)'")
		}

		let citation = try cited(arguments)
		let markdown = try Self.markdown(arguments)
		let quote = try arguments.string("quote")
		guard BoardQuote.normalized(quote).count >= Self.quoteMinimum else {
			throw AskTools.Failure(message: "Expected a 'quote' of at least \(Self.quoteMinimum) characters")
		}
		guard texts.contains(where: { BoardQuote.isQuote(quote, in: $0) }) else {
			throw AskTools.Failure(message: "The quote '\(quote)' isn't in the text of that \(kind), copy the words exactly")
		}

		try reserve("annotate/\(kind)/\(id)/\(citation.category)/\(citation.id)", duplicate: "That \(kind) already has an annotation citing \(citation.name)")
		let report = BoardAnalysisReport(
			target: target,
			citation: citation,
			quote: quote,
			markdown: markdown,
			assessment: nil,
			objection: arguments.optionalString("objection"),
			isKey: arguments.optionalString("importance") == "key"
		)
		return AskToolReply(text: "Added the annotation", event: .report(report))
	}

	func assessArrow(_ arguments: Arguments) throws(AskTools.Failure) -> AskToolReply<BoardAnalysisEvent> {
		let id = try arguments.id("link_id")
		guard request.links.contains(where: { $0.id == id }) else { throw missing("link", id) }
		let strength = try arguments.string("strength")
		guard let value = BoardArrowStrength(rawValue: strength) else {
			throw AskTools.Failure(message: "Expected 'strength' to be one of \(BoardArrowStrength.allCases.map(\.rawValue).joined(separator: ", ")), found '\(strength)'")
		}
		let citation = try cited(arguments)
		let markdown = try Self.markdown(arguments)

		try reserve("arrow/\(id)", duplicate: "That link is already assessed")
		let report = BoardAnalysisReport(target: .link(id), citation: citation, quote: nil, markdown: markdown, assessment: .arrow(value))
		return AskToolReply(text: "Recorded the assessment of the link", event: .report(report))
	}

	func assessConclusion(_ arguments: Arguments) throws(AskTools.Failure) -> AskToolReply<BoardAnalysisEvent> {
		let id = try arguments.id("statement_id")
		guard request.statements.contains(where: { $0.id == id }) else { throw missing("statement", id) }
		guard request.links.contains(where: { $0.conclusion == id }) else {
			throw AskTools.Failure(message: "No link leads to the statement \(id), only assess a statement that others are premises of")
		}
		let support = try arguments.string("support")
		guard let value = BoardConclusionSupport(rawValue: support) else {
			throw AskTools.Failure(message: "Expected 'support' to be one of \(BoardConclusionSupport.allCases.map(\.rawValue).joined(separator: ", ")), found '\(support)'")
		}
		let citation = try cited(arguments)
		let markdown = try Self.markdown(arguments)

		try reserve("conclusion/\(id)", duplicate: "That statement is already assessed")
		let report = BoardAnalysisReport(target: .statement(id), citation: citation, quote: nil, markdown: markdown, assessment: .conclusion(value))
		return AskToolReply(text: "Recorded the assessment of the statement", event: .report(report))
	}

	// MARK: - Checks

	func missing(_ kind: String, _ id: UUID) -> AskTools.Failure {
		AskTools.Failure(message: "No \(kind) in this board has the id '\(id.uuidString)'")
	}

	/// The entry being cited: in any category but symbols, and one this run has read
	func cited(_ arguments: Arguments) throws(AskTools.Failure) -> LibraryCitation {
		let (category, id) = try (arguments.string("category"), arguments.string("id"))
		guard category != "symbols" else {
			throw AskTools.Failure(message: "Expected 'category' to be any but symbols, which are logic and aren't cited")
		}
		guard let entry = catalog.entry(category: category, id: id) else {
			throw AskTools.Failure(message: "No \(category) entry has the id '\(id)', search for it first")
		}
		guard locked({ $0.read.contains("\(category)/\(id)") }) else {
			throw AskTools.Failure(message: "Read \(entry.name) with get_library_entry before citing it")
		}
		return LibraryCitation(category: category, id: id, name: entry.name)
	}

	static func markdown(_ arguments: Arguments) throws(AskTools.Failure) -> String {
		let text = try arguments.string("markdown").trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty else {
			throw AskTools.Failure(message: "Expected 'markdown'")
		}
		guard text.count <= markdownLimit else {
			throw AskTools.Failure(message: "Expected 'markdown' of at most \(markdownLimit) characters, found \(text.count)")
		}
		return text
	}

	/// Counts a report that passed every other check, or refuses it
	func reserve(_ key: String, duplicate: String) throws(AskTools.Failure) {
		let refusal: String? = locked { state in
			if state.reported.count >= reportBudget {
				return "Expected at most \(reportBudget) reports, stop reporting"
			}
			if !state.reported.insert(key).inserted {
				return duplicate
			}
			return nil
		}
		if let refusal {
			throw AskTools.Failure(message: refusal)
		}
	}
}
