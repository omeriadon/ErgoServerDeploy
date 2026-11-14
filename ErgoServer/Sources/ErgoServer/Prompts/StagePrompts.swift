//
//  StagePrompts.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoProtocol
import Foundation

/// What each stage's model is told. The instructions live in `Prompts/<Feature>/<stage>.md`, the input travels as JSON,
/// so the user's English only ever reaches a model as a JSON string inside data, never in an instruction.
enum StagePrompts {
	struct Missing: Error, CustomStringConvertible {
		let stage: String

		var description: String {
			"Missing instrucfftions for the '\(stage)' stage"
		}
	}

	/// Added to Ask's instructions for a chat about a board
	static let board = "board"

	/// Added to a deep research run's instructions when it may search the web
	static let web = "web"

	private static let names = StageModels.stages + [StageModels.ask, StageModels.analyse, StageModels.title, board, web]
		+ AskMode.allCases.filter { $0 != .normal }.map(\.rawValue)

	private static let all: [String: String] = Dictionary(uniqueKeysWithValues: names.compactMap { stage in
		Bundle.module.url(forResource: stage, withExtension: "md")
			.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
			.map { (stage, $0) }
	})

	/// Checked at launch, so a broken bundle never gets as far as a translation
	static var missing: [String] {
		names.filter { all[$0] == nil }
	}

	static func instructions(for stage: String) throws -> String {
		guard let instructions = all[stage] else {
			throw Missing(stage: stage)
		}
		return instructions
	}

	/// The conversation as data too, so what's pasted into it can't pass for an instruction
	static func askMessage(for messages: [AskRequestMessage], instructions: String? = nil, mode: AskMode = .normal, board: AskBoard? = nil) throws -> String {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
		let json = try String(decoding: encoder.encode(messages), as: UTF8.self)

		var about = ""
		if let board {
			encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
			about = try """
			The board this chat is about, as it is now:

			```json
			\(String(decoding: encoder.encode(board), as: UTF8.self))
			```


			"""
		}
		// A mode or a board has rules of its own about what you may say from your own reasoning
		let ending = mode == .normal && board == nil
			? "Answer the last message. Search and read the library first, and only say what the entries you read this turn say. Your own knowledge isn't a source here."
			: "Answer the last message, by the rules of this chat's mode. Anything you name still comes from a library entry you read this turn."

		return """
		\(about)The conversation so far:

		```json
		\(json)
		```

		\(ending)
		\(instructionsNote(instructions))
		"""
	}

	/// The person's own words about how to answer, kept apart so they can't loosen the rules above. Empty when there are none.
	static func instructionsNote(_ instructions: String?) -> String {
		guard let instructions = AgentInstructions.normalized(instructions) else { return "" }
		return """


		The person asked for this about how you answer. It's about style only, like length and tone, and doesn't change what counts as a source, how to use your tools or the format you answer in:

		\(instructions)
		"""
	}

	/// The board as data, so what's in a card or a page can't pass for an instruction
	static func analysisMessage(for request: BoardAnalysisRequest) throws -> String {
		struct Board: Encodable {
			let statements: [BoardAnalysisRequest.Statement]
			let links: [BoardAnalysisRequest.Link]
			let sources: [BoardAnalysisRequest.Source]
		}
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
		let json = try String(decoding: encoder.encode(Board(statements: request.statements, links: request.links, sources: request.sources)), as: UTF8.self)

		return """
		The board:

		```json
		\(json)
		```

		Work out where this argument's weight rests and where it breaks, then report what matters most. Your reasoning is your own, but anything you name comes from an entry you read this run.
		\(instructionsNote(request.instructions))
		"""
	}

	/// One pass of a board's analysis. A board read in one go is `analysisMessage(for:)`. When a long source is read in
	/// parts, the first comes with the board and the rest on their own, with the cards and arrows as context only, since
	/// those passes can't report on them.
	static func analysisMessage(for pass: BoardAnalysisPass, board: BoardAnalysisRequest) throws -> String {
		guard pass.count > 1 else {
			return try analysisMessage(for: pass.request)
		}
		struct Part: Encodable {
			let id: UUID
			let title: String
			/// "2 of 5", left out for a source that's whole
			let part: String?
			let text: String
		}
		struct Board: Encodable {
			let statements: [BoardAnalysisRequest.Statement]
			let links: [BoardAnalysisRequest.Link]
			let sources: [Part]?
		}
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
		let sources = pass.request.sources.map { source in
			Part(id: source.id, title: source.title, part: pass.parts[source.id].map { "\(pass.number) of \($0)" }, text: source.text)
		}
		func json(_ value: some Encodable) throws -> String {
			try String(decoding: encoder.encode(value), as: UTF8.self)
		}

		if pass.isFirst {
			return try """
			The board:

			```json
			\(json(Board(statements: pass.request.statements, links: pass.request.links, sources: sources)))
			```

			A source with a `part` is long, so this is only the first part of its text, and you'll be given the rest afterwards, a part at a time. Annotate what's here.

			Work out where this argument's weight rests and where it breaks, then report what matters most. Your reasoning is your own, but anything you name comes from an entry you read this run.
			\(instructionsNote(board.instructions))
			"""
		}
		return try """
		The board's cards and arrows, for context only. They were annotated and assessed with the first part, so don't report on them:

		```json
		\(json(Board(statements: board.statements, links: board.links, sources: nil)))
		```

		The next part of each long source:

		```json
		\(json(sources))
		```

		Annotate what matters in these parts, with each quote copied from the part it's about. A finding you'd make again about the same entry is still worth making when it's about new words. Write nothing outside your tool calls: the overall discussion was written with the first part.
		\(instructionsNote(board.instructions))
		"""
	}

	static func message(for input: some Encodable) throws -> String {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
		let json = try String(decoding: encoder.encode(input), as: UTF8.self)

		return """
		Input:

		```json
		\(json)
		```

		Answer with only a JSON object that matches the schema.
		"""
	}
}
