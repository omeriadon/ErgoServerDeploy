//
//  AskTools.swift
//  ErgoKit
//
//  Created by Adon Omeri on 6/11/2026.
//

import ErgoCatalog
import ErgoProtocol
import ErgoSync
import Foundation

/// What the model can do while answering: read the library, and suggest something for the device to do.
/// The reading runs right here, wherever this is. What needs the device comes back to the app as an `AskAction`.
public struct AskTools: Sendable {
	public struct Failure: Error, Hashable {
		public let message: String
	}

	public let catalog: LibraryCatalog

	public init(catalog: LibraryCatalog) {
		self.catalog = catalog
	}

	// MARK: - Definitions

	static let categoryProperty: JSONValue = .object([
		"type": .string("string"),
		"enum": .array(LibraryCatalog.categories.map(JSONValue.string)),
	])

	static func schema(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
		.object([
			"type": .string("object"),
			"properties": .object(properties),
			"required": .array(required.map(JSONValue.string)),
			"additionalProperties": .bool(false),
		])
	}

	static func definition(_ name: String, _ description: String, _ schema: JSONValue) -> JSONValue {
		.object(["name": .string(name), "description": .string(description), "inputSchema": schema])
	}

	public static let names = ["search_library", "get_library_entry", "list_library", "suggest_action", "request_change_mode"]

	public static let definitions: [JSONValue] = [
		definition(
			"search_library",
			"Searches Ergo's library of biases, concepts, fallacies, logic symbols, paradoxes, philosophers, razors and arguments. Returns each match's summary and the markdown link to cite it with.",
			schema(["query": .object(["type": .string("string")]), "category": categoryProperty], required: ["query"])
		),
		definition(
			"get_library_entry",
			"Reads one library entry in full, by the category and id search_library or list_library gave.",
			schema(["category": categoryProperty, "id": .object(["type": .string("string")])], required: ["category", "id"])
		),
		definition(
			"list_library",
			"Lists one category of the library, by name, optionally only the entries with a tag.",
			schema(["category": categoryProperty, "tag": .object(["type": .string("string")])], required: ["category"])
		),
		definition(
			"suggest_action",
			"Adds a button under your answer that the user can tap. ask_follow_up puts a question in the box they type in, for them to edit or send. The others open part of the app.",
			schema(
				[
					"title": .object(["type": .string("string"), "description": .string("What the button says, at most four words")]),
					"action": .object(["type": .string("string"), "enum": .array(["ask_follow_up", "open_library_entry", "show_library_list", "open_bookmarks", "open_tab"].map(JSONValue.string))]),
					"text": .object(["type": .string("string"), "description": .string("For ask_follow_up: the question, as the user would ask it")]),
					"category": categoryProperty,
					"id": .object(["type": .string("string"), "description": .string("For open_library_entry")]),
					"tab": .object(["type": .string("string"), "enum": .array(["board", "logic", "ask", "library"].map(JSONValue.string))]),
				],
				required: ["title", "action"]
			)
		),
		definition(
			"request_change_mode",
			"Asks the person to switch this chat's mode. debate argues the other side of something with them. scout goes through a text and finds its fallacies and other problems. normal goes back to answering questions. They accept or turn it down, so say in one line what you're asking and then stop.",
			schema(
				[
					"mode": .object(["type": .string("string"), "enum": .array(AskMode.allCases.map { .string($0.rawValue) })]),
					"reason": .object(["type": .string("string"), "description": .string("What it's for, at most eight words, like 'Argue about free will'")]),
				],
				required: ["mode", "reason"]
			)
		),
	]

	// MARK: - Calling

	public enum Outcome: Hashable, Sendable {
		/// For the model
		case text(String)

		/// For the model, and a button for the app
		case action(AskAction, text: String)

		/// For the model, and a question for the person
		case modeRequest(AskModeRequest, text: String)
	}

	/// Failures are worded for the model to put right
	public func call(_ name: String, arguments: [String: JSONValue]) throws(Failure) -> Outcome {
		func string(_ key: String) -> String? {
			guard case let .string(value)? = arguments[key], !value.isEmpty else { return nil }
			return value
		}
		func required(_ key: String) throws(Failure) -> String {
			guard let value = string(key) else {
				throw Failure(message: "Expected '\(key)'")
			}
			return value
		}

		switch name {
			case "search_library":
				return try .text(Self.encoded(catalog.search(required("query"), category: string("category")).map(Self.brief)))

			case "get_library_entry":
				let (category, id) = try (required("category"), required("id"))
				guard let entry = catalog.entry(category: category, id: id) else {
					throw Failure(message: "No \(category) entry has the id '\(id)', search for it first")
				}
				return .text(#"{"link": \#(Self.quoted(Self.link(to: entry))), "entry": \#(entry.details)}"#)

			case "list_library":
				return try .text(Self.encoded(catalog.list(category: required("category"), tag: string("tag")).map(Self.brief)))

			case "suggest_action":
				let action = try action(title: required("title"), kind: required("action"), text: string("text"), category: string("category"), id: string("id"), tab: string("tab"))
				return .action(action, text: "Added the button '\(action.title)'")

			case "request_change_mode":
				let name = try required("mode")
				guard let mode = AskMode.allCases.first(where: { $0.rawValue == name }) else {
					throw Failure(message: "Expected 'mode' to be one of \(AskMode.allCases.map(\.rawValue).joined(separator: ", ")), found '\(name)'")
				}
				return try .modeRequest(AskModeRequest(mode: mode, reason: required("reason")), text: "Asked the person. Stop here and wait for them.")

			default:
				throw Failure(message: "No tool is called '\(name)'")
		}
	}

	private func action(title: String, kind: String, text: String?, category: String?, id: String?, tab: String?) throws(Failure) -> AskAction {
		let intent: AskIntent
		switch kind {
			case "ask_follow_up":
				guard let text else {
					throw Failure(message: "Expected the 'text' of the question")
				}
				intent = .askFollowUp(text)
			case "open_library_entry":
				guard let category, let id, catalog.entry(category: category, id: id) != nil else {
					throw Failure(message: "Expected the 'category' and 'id' of a library entry")
				}
				intent = .openLibraryEntry(category: category, id: id)
			case "show_library_list":
				guard let category, LibraryCatalog.categories.contains(category) else {
					throw Failure(message: "Expected a library 'category'")
				}
				intent = .showLibraryList(category: category)
			case "open_bookmarks":
				intent = .openBookmarks
			case "open_tab":
				guard let tab, ["board", "logic", "ask", "library"].contains(tab) else {
					throw Failure(message: "Expected a 'tab'")
				}
				intent = .openTab(tab)
			default:
				throw Failure(message: "No action is called '\(kind)'")
		}
		return AskAction(title: title, intent: intent)
	}

	/// What to show while a tool runs
	public func activity(_ name: String, arguments: [String: JSONValue]) -> AskToolActivity? {
		func string(_ key: String) -> String? {
			guard case let .string(value)? = arguments[key] else { return nil }
			return value
		}
		switch name {
			case "search_library":
				let query = string("query") ?? ""
				return AskToolActivity(tool: name, summary: "Searching the library for '\(query)'", record: "Searched the library for '\(query)'")
			case "get_library_entry":
				let entry = string("category").flatMap { category in string("id").flatMap { catalog.entry(category: category, id: $0) } }
				let name = entry?.name ?? "the library"
				return AskToolActivity(tool: "get_library_entry", summary: "Reading \(name)", record: "Read \(name)")
			case "list_library":
				let category = string("category") ?? "the library"
				return AskToolActivity(tool: name, summary: "Looking through \(category)", record: "Looked through \(category)")
			default:
				return nil
		}
	}

	// MARK: - Text for the model

	private struct Brief: Encodable {
		let category: String
		let id: String
		let name: String
		let summary: String
		let tags: [String]
		let link: String
	}

	private static func brief(_ entry: LibraryEntryText) -> Brief {
		Brief(category: entry.category, id: entry.id, name: entry.name, summary: entry.summary, tags: entry.tags, link: link(to: entry))
	}

	/// The markdown the model writes to cite an entry
	public static func link(to entry: LibraryEntryText) -> String {
		let url = AskIntent.openLibraryEntry(category: entry.category, id: entry.id).url?.absoluteString ?? ""
		return "[\(entry.name)](\(url))"
	}

	private static func encoded(_ value: some Encodable) -> String {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
	}

	private static func quoted(_ text: String) -> String {
		encoded([text]).dropFirst().dropLast().description
	}
}
