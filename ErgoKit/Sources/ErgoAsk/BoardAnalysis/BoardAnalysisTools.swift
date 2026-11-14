//
//  BoardAnalysisTools.swift
//  ErgoKit
//
//  Created by Adon Omeri on 8/11/2026.
//

import ErgoCatalog
import ErgoProtocol
import ErgoSync
import Foundation

/// A report that passed every check, as the model made it. The server gives it an id and `BoardAnnotation` form.
public struct BoardAnalysisReport: Sendable, Hashable {
	public let target: BoardAnalysisTarget
	public let citation: LibraryCitation

	/// Nil only on assessments
	public let quote: String?
	public let markdown: String
	public let assessment: BoardAnnotation.Assessment?
	public let objection: String?
	public let isKey: Bool

	public init(target: BoardAnalysisTarget, citation: LibraryCitation, quote: String?, markdown: String, assessment: BoardAnnotation.Assessment?, objection: String? = nil, isKey: Bool = false) {
		self.target = target
		self.citation = citation
		self.quote = quote
		self.markdown = markdown
		self.assessment = assessment
		self.objection = objection
		self.isKey = isKey
	}

	/// The annotation to save, with what it was judged on: a conclusion or arrow's conclusion and all its premises, so an
	/// edit to any of them, or a premise coming or going, makes it stale. A source's own title, which is how a link
	/// source is known to be unchanged.
	public func annotation(id: UUID = UUID(), board: UUID, in request: BoardAnalysisRequest) -> BoardAnnotation {
		var basis: [UUID: String] = [:]
		switch (assessment, target) {
			case let (.arrow?, .link(link)):
				if let conclusion = request.links.first(where: { $0.id == link })?.conclusion {
					basis = Self.basis(of: conclusion, in: request)
				}
			case let (.conclusion?, .statement(conclusion)):
				basis = Self.basis(of: conclusion, in: request)
			case let (nil, .source(source)):
				basis[source] = request.sources.first { $0.id == source }?.title
			default:
				break
		}
		return BoardAnnotation(id: id, board: board, run: request.run, target: target, citation: citation, quote: quote, markdown: markdown, assessment: assessment, objection: objection, isKey: isKey, basis: basis)
	}

	static func basis(of conclusion: UUID, in request: BoardAnalysisRequest) -> [UUID: String] {
		let ids = [conclusion] + request.links.filter { $0.conclusion == conclusion }.map(\.premise)
		return Dictionary(request.statements.filter { ids.contains($0.id) }.map { ($0.id, $0.english) }) { first, _ in first }
	}
}

/// What a board analysis run reports as its tools work
public enum BoardAnalysisEvent: Sendable, Hashable {
	case tool(AskToolActivity)
	case report(BoardAnalysisReport)
}

/// What the model can do while analysing one board: read the library, and report what it finds. Every report is
/// checked here before the job hears of it, and a refused one goes back to the model as an error to put right.
/// Built for one run, since what it has read so far is part of what it accepts.
public final class BoardAnalysisTools: AskToolSet, @unchecked Sendable {
	public static let reportLimit = 150
	public static let quoteMinimum = 3
	public static let markdownLimit = 20000

	/// Everything a run may call, for Claude Code's command line
	public static let names = ["search_library", "get_library_entry", "list_library", "annotate", "assess_arrow", "assess_conclusion"]

	public let request: BoardAnalysisRequest
	public let catalog: LibraryCatalog

	/// How many reports this set takes: `reportLimit`, or what a run in parts has left of it
	public let reportBudget: Int

	let library: AskTools

	/// What the run has done so far, behind a lock since calls can overlap
	struct State {
		var read: Set<String> = []
		var reported: Set<String> = []
	}

	let lock = NSLock()
	var state = State()

	public init(request: BoardAnalysisRequest, catalog: LibraryCatalog, reportBudget: Int = BoardAnalysisTools.reportLimit) {
		self.request = request
		self.catalog = catalog
		self.reportBudget = reportBudget
		library = AskTools(catalog: catalog)
	}

	// MARK: - Calling

	public func reply(to name: String, arguments: [String: JSONValue]) throws(AskTools.Failure) -> AskToolReply<BoardAnalysisEvent> {
		switch name {
			case "search_library", "list_library":
				return try AskToolReply(text: text(library.call(name, arguments: arguments)))

			case "get_library_entry":
				let outcome = try library.call(name, arguments: arguments)
				if case let .string(category)? = arguments["category"], case let .string(id)? = arguments["id"] {
					locked { $0.read.insert("\(category)/\(id)") }
				}
				return AskToolReply(text: text(outcome))

			case "annotate":
				return try annotate(Arguments(arguments))

			case "assess_arrow":
				return try assessArrow(Arguments(arguments))

			case "assess_conclusion":
				return try assessConclusion(Arguments(arguments))

			default:
				throw AskTools.Failure(message: "No tool is called '\(name)'")
		}
	}

	public func event(running name: String, arguments: [String: JSONValue]) -> BoardAnalysisEvent? {
		switch name {
			case "search_library", "get_library_entry", "list_library":
				library.activity(name, arguments: arguments).map(BoardAnalysisEvent.tool)
			default:
				nil
		}
	}

	func text(_ outcome: AskTools.Outcome) -> String {
		switch outcome {
			case let .text(text), let .action(_, text), let .modeRequest(_, text):
				text
		}
	}

	func locked<Result>(_ body: (inout State) -> Result) -> Result {
		lock.lock()
		defer { lock.unlock() }
		return body(&state)
	}
}
