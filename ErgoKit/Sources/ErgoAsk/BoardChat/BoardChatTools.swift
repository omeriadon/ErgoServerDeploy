//
//  BoardChatTools.swift
//  ErgoKit
//
//  Created by Adon Omeri on 10/11/2026.
//

import ErgoCatalog
import ErgoProtocol
import ErgoSync
import Foundation

/// What the model can do in a chat about a board: everything Ask can, and change the board. It keeps its own copy of the
/// board as it goes, so a card it just added can be connected, and every change is checked here before the device hears of it.
/// Built for one run.
public final class BoardChatTools: AskToolSet, @unchecked Sendable {
	public static let editLimit = 60
	public static let cardLimit = 600

	static let readingNames = ["search_library", "get_library_entry", "list_library", "suggest_action"]
	static let editingNames = ["add_card", "edit_card", "delete_card", "connect_cards", "disconnect_cards"]

	/// Everything a run may call, for Claude Code's command line
	public static func names(canEdit: Bool) -> [String] {
		readingNames + (canEdit ? editingNames : [])
	}

	private struct State {
		var cards: [UUID: String]
		var links: Set<Pair>
		var edits = 0
	}

	private struct Pair: Hashable {
		let premise: UUID
		let conclusion: UUID
	}

	private let library: AskTools
	private let canEdit: Bool
	private let lock = NSLock()
	private var state: State

	public init(board: AskBoard, catalog: LibraryCatalog) {
		library = AskTools(catalog: catalog)
		canEdit = board.canEdit
		state = State(
			cards: Dictionary(board.statements.map { ($0.id, $0.english) }) { first, _ in first },
			links: Set(board.links.map { Pair(premise: $0.premise, conclusion: $0.conclusion) })
		)
	}

	// MARK: - Definitions

	private static let id = BoardAnalysisTools.property("The id of a card on the board, or one add_card gave you")

	private static let editing: [JSONValue] = [
		AskTools.definition(
			"add_card",
			"Adds a card to the board: one claim in plain English. Returns its id. To add an objection, add it as a card beside what it objects to, without an arrow, since an arrow always means support.",
			AskTools.schema(
				[
					"english": BoardAnalysisTools.property("The claim, in one sentence"),
					"near": BoardAnalysisTools.property("The id of the card to put it beside, if any"),
				],
				required: ["english"]
			)
		),
		AskTools.definition("edit_card", "Replaces a card's words.", AskTools.schema(["id": id, "english": BoardAnalysisTools.property("The new words")], required: ["id", "english"])),
		AskTools.definition("delete_card", "Deletes a card and its arrows. Only when the person asked for it.", AskTools.schema(["id": id], required: ["id"])),
		AskTools.definition("connect_cards", "Draws an arrow saying one card is a premise of another.", AskTools.schema(["premise": id, "conclusion": id], required: ["premise", "conclusion"])),
		AskTools.definition("disconnect_cards", "Removes the arrow between a premise and a conclusion.", AskTools.schema(["premise": id, "conclusion": id], required: ["premise", "conclusion"])),
	]

	public var definitions: [JSONValue] {
		let names = Self.names(canEdit: canEdit)
		return (AskTools.definitions + Self.editing).filter { definition in
			guard case let .object(object) = definition, case let .string(name)? = object["name"] else { return false }
			return names.contains(name)
		}
	}

	// MARK: - Calling

	public func event(running name: String, arguments: [String: JSONValue]) -> AskServerMessage? {
		library.activity(name, arguments: arguments).map(AskServerMessage.tool)
	}

	public func reply(to name: String, arguments: [String: JSONValue]) throws(AskTools.Failure) -> AskToolReply<AskServerMessage> {
		guard Self.editingNames.contains(name) else {
			guard Self.readingNames.contains(name) else {
				throw AskTools.Failure(message: "No tool is called '\(name)'")
			}
			return try library.reply(to: name, arguments: arguments)
		}
		guard canEdit else {
			throw AskTools.Failure(message: "This board is view only, so it can't be changed")
		}
		return try edit(name, BoardAnalysisTools.Arguments(arguments))
	}

	private func edit(_ name: String, _ arguments: BoardAnalysisTools.Arguments) throws(AskTools.Failure) -> AskToolReply<AskServerMessage> {
		lock.lock()
		defer { lock.unlock() }

		guard state.edits < Self.editLimit else {
			throw AskTools.Failure(message: "Expected at most \(Self.editLimit) changes in one answer, tell the person what's left to do")
		}

		let change: AskBoardEdit.Change
		let text: String
		switch name {
			case "add_card":
				let english = try Self.english(arguments)
				guard state.cards.count < Self.cardLimit else {
					throw AskTools.Failure(message: "The board is full")
				}
				var near: UUID?
				if arguments.values["near"] != nil {
					near = try card("near", arguments)
				}
				let id = UUID()
				state.cards[id] = english
				change = .addCard(id: id, english: english, near: near)
				text = #"{"id": "\#(id.uuidString)"}"#

			case "edit_card":
				let (id, english) = try (card("id", arguments), Self.english(arguments))
				state.cards[id] = english
				change = .editCard(id: id, english: english)
				text = "Changed the card"

			case "delete_card":
				let id = try card("id", arguments)
				state.cards[id] = nil
				state.links = state.links.filter { $0.premise != id && $0.conclusion != id }
				change = .deleteCard(id: id)
				text = "Deleted the card"

			case "connect_cards":
				let (premise, conclusion) = try (card("premise", arguments), card("conclusion", arguments))
				guard premise != conclusion else {
					throw AskTools.Failure(message: "A card can't be a premise of itself")
				}
				guard !state.links.contains(Pair(premise: premise, conclusion: conclusion)) else {
					throw AskTools.Failure(message: "That arrow is already there")
				}
				guard !reaches(from: conclusion, to: premise) else {
					throw AskTools.Failure(message: "That arrow would make a loop, where a card ends up supporting itself")
				}
				state.links.insert(Pair(premise: premise, conclusion: conclusion))
				change = .connect(premise: premise, conclusion: conclusion)
				text = "Drew the arrow"

			default:
				let (premise, conclusion) = try (card("premise", arguments), card("conclusion", arguments))
				guard state.links.remove(Pair(premise: premise, conclusion: conclusion)) != nil else {
					throw AskTools.Failure(message: "There's no arrow from that premise to that conclusion")
				}
				change = .disconnect(premise: premise, conclusion: conclusion)
				text = "Removed the arrow"
		}
		state.edits += 1
		return AskToolReply(text: text, event: .boardEdit(AskBoardEdit(change: change)))
	}

	// MARK: - Checks

	private func card(_ key: String, _ arguments: BoardAnalysisTools.Arguments) throws(AskTools.Failure) -> UUID {
		let id = try arguments.id(key)
		guard state.cards[id] != nil else {
			throw AskTools.Failure(message: "No card on this board has the id '\(id.uuidString)'")
		}
		return id
	}

	private static func english(_ arguments: BoardAnalysisTools.Arguments) throws(AskTools.Failure) -> String {
		let english = try arguments.string("english").trimmingCharacters(in: .whitespacesAndNewlines)
		guard !english.isEmpty else {
			throw AskTools.Failure(message: "Expected 'english'")
		}
		return english
	}

	/// Whether arrows lead from one card to the other
	private func reaches(from start: UUID, to target: UUID) -> Bool {
		var seen: Set<UUID> = []
		var waiting = [start]
		while let card = waiting.popLast() {
			if card == target {
				return true
			}
			guard seen.insert(card).inserted else { continue }
			waiting += state.links.filter { $0.premise == card }.map(\.conclusion)
		}
		return false
	}
}
