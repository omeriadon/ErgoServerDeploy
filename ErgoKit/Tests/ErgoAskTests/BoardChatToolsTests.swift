//
//  BoardChatToolsTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 10/11/2026.
//

import ErgoAsk
import ErgoCatalog
import ErgoProtocol
import ErgoSync
import Foundation
import Testing

struct BoardChatToolsTests {
	static let rain = UUID()
	static let wet = UUID()
	static let catalog = LibraryCatalog(entries: [])

	static func tools(canEdit: Bool = true) -> BoardChatTools {
		BoardChatTools(
			board: AskBoard(
				title: "Weather",
				canEdit: canEdit,
				statements: [.init(id: rain, english: "It rained."), .init(id: wet, english: "The ground is wet.")],
				links: [],
				sources: []
			),
			catalog: catalog
		)
	}

	static func edit(_ reply: AskToolReply<AskServerMessage>) -> AskBoardEdit.Change? {
		if case let .boardEdit(edit)? = reply.event {
			return edit.change
		}
		return nil
	}

	static func refusal(_ tools: BoardChatTools, _ name: String, _ arguments: [String: JSONValue]) -> String? {
		do {
			_ = try tools.reply(to: name, arguments: arguments)
			return nil
		} catch {
			return error.message
		}
	}

	static func connect(_ tools: BoardChatTools, _ premise: UUID, _ conclusion: UUID) -> String? {
		refusal(tools, "connect_cards", ["premise": .string(premise.uuidString), "conclusion": .string(conclusion.uuidString)])
	}

	@Test func aNewCardCanBeConnectedStraightAway() throws {
		let tools = Self.tools()
		let reply = try tools.reply(to: "add_card", arguments: ["english": "Puddles formed."])
		guard case let .addCard(id, english, near)? = Self.edit(reply) else {
			Issue.record("Expected a new card")
			return
		}
		#expect(english == "Puddles formed.")
		#expect(near == nil)
		#expect(reply.text.contains(id.uuidString))
		#expect(Self.connect(tools, Self.rain, id) == nil)
	}

	@Test func aLoopIsRefused() {
		let tools = Self.tools()
		#expect(Self.connect(tools, Self.rain, Self.wet) == nil)
		#expect(Self.connect(tools, Self.wet, Self.rain)?.contains("loop") == true)
		#expect(Self.connect(tools, Self.rain, Self.wet)?.contains("already") == true)
		#expect(Self.connect(tools, Self.rain, Self.rain) != nil)
	}

	@Test func anUnknownCardIsRefused() {
		#expect(Self.connect(Self.tools(), Self.rain, UUID())?.contains("No card") == true)
	}

	@Test func aDeletedCardIsGoneAndItsArrowsWithIt() throws {
		let tools = Self.tools()
		#expect(Self.connect(tools, Self.rain, Self.wet) == nil)
		_ = try tools.reply(to: "delete_card", arguments: ["id": .string(Self.wet.uuidString)])
		#expect(Self.refusal(tools, "edit_card", ["id": .string(Self.wet.uuidString), "english": "Dry."]) != nil)
	}

	@Test func aViewOnlyBoardGetsNoEditing() {
		let tools = Self.tools(canEdit: false)
		#expect(BoardChatTools.names(canEdit: false) == ["search_library", "get_library_entry", "list_library", "suggest_action"])
		#expect(Self.refusal(tools, "add_card", ["english": "Hello."])?.contains("view only") == true)
	}

	@Test func theDefinitionsMatchTheNames() {
		for canEdit in [true, false] {
			let names = Self.tools(canEdit: canEdit).definitions.compactMap { definition -> String? in
				guard case let .object(object) = definition, case let .string(name)? = object["name"] else { return nil }
				return name
			}
			#expect(Set(names) == Set(BoardChatTools.names(canEdit: canEdit)))
		}
	}

	@Test func theModelCanAskToChangeMode() throws {
		let tools = AskTools(catalog: Self.catalog)
		let reply = try tools.reply(to: "request_change_mode", arguments: ["mode": "debate", "reason": "Argue about free will"])
		#expect(reply.event == .modeRequest(AskModeRequest(mode: .debate, reason: "Argue about free will")))
		#expect(throws: AskTools.Failure.self) {
			_ = try tools.reply(to: "request_change_mode", arguments: ["mode": "sing", "reason": "x"])
		}
	}
}
