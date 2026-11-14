//
//  BoardAnalysisTools+Definitions.swift
//  Ergo
//
//  Created by Adon Omeri on 8/11/2026.
//

import ErgoCatalog
import ErgoProtocol
import ErgoSync
import Foundation

extension BoardAnalysisTools {
	// MARK: - Definitions

	static func property(_ description: String, values: [String]? = nil) -> JSONValue {
		var property: [String: JSONValue] = ["type": .string("string"), "description": .string(description)]
		if let values {
			property["enum"] = .array(values.map(JSONValue.string))
		}
		return .object(property)
	}

	static let citation: [String: JSONValue] = [
		"category": AskTools.categoryProperty,
		"id": property("The id of the library entry you read with get_library_entry in this run"),
	]

	static let markdown = property("What to say, in markdown, at most \(markdownLimit) characters. It can discuss at length and link other library entries with the links the library tools give.")

	public var definitions: [JSONValue] {
		let reading = AskTools.definitions.filter { definition in
			guard case let .object(object) = definition, case let .string(name)? = object["name"] else { return false }
			return Self.names.contains(name)
		}
		return reading + [
			AskTools.definition(
				"annotate",
				"Annotates a statement, link or source with a library entry that is relevant to it, quoting the words it is about. You must have read that entry with get_library_entry in this run. Annotate nothing when nothing is relevant.",
				AskTools.schema(
					[
						"target_kind": Self.property("What the quote is from", values: ["statement", "link", "source"]),
						"target_id": Self.property("The id of that statement, link or source"),
						"quote": Self.property("Words copied exactly from the target's text, at least \(Self.quoteMinimum) characters. For a link, from either of its two statements."),
						"markdown": Self.markdown,
						"importance": Self.property("key for the two or three findings that matter most on the whole board, otherwise leave it out", values: ["key", "normal"]),
						"objection": Self.property("The strongest objection to this claim, written as one claim someone could put on the board. Leave it out unless there is a real one."),
					].merging(Self.citation) { $1 },
					required: ["target_kind", "target_id", "category", "id", "quote", "markdown"]
				)
			),
			AskTools.definition(
				"assess_arrow",
				"Assesses one link: how far its premise, taken as true and alongside the conclusion's other premises, supports the conclusion. Judge the inference, never whether the premise is true. Once per link.",
				AskTools.schema(
					[
						"link_id": Self.property("The id of the link"),
						"strength": Self.property("How far the premise supports the conclusion", values: BoardArrowStrength.allCases.map(\.rawValue)),
						"markdown": Self.markdown,
					].merging(Self.citation) { $1 },
					required: ["link_id", "strength", "category", "id", "markdown"]
				)
			),
			AskTools.definition(
				"assess_conclusion",
				"Assesses one statement that other statements are premises of: how well all its premises together support it. Once per statement.",
				AskTools.schema(
					[
						"statement_id": Self.property("The id of the statement"),
						"support": Self.property("How well its premises support it", values: BoardConclusionSupport.allCases.map(\.rawValue)),
						"markdown": Self.markdown,
					].merging(Self.citation) { $1 },
					required: ["statement_id", "support", "category", "id", "markdown"]
				)
			),
		]
	}
}
