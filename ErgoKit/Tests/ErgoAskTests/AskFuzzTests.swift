//
//  AskFuzzTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 11/11/2026.
//

import ErgoAsk
import ErgoCatalog
import ErgoProtocol
import ErgoSync
import Foundation
import Testing

/// The tools are called by a model, over a port anyone on the machine could find. Whatever arrives, the answer is a
/// JSON-RPC reply or nothing, and a board only ever changes into another board that makes sense.
struct AskFuzzTests {
	static let catalog = LibraryCatalog.shared ?? LibraryCatalog(entries: [])

	// MARK: - The tool server

	static let bodies = [
		"", " ", "null", "[]", "{}", "7", "\"text\"", "{", "}", "[{}]", "\u{0}",
		#"{"jsonrpc":"2.0"}"#,
		#"{"jsonrpc":"2.0","id":1}"#,
		#"{"jsonrpc":"2.0","id":1,"method":7}"#,
		#"{"jsonrpc":"2.0","id":null,"method":"tools/list"}"#,
		#"{"jsonrpc":"2.0","id":{"a":[1,2]},"method":"tools/list"}"#,
		#"{"jsonrpc":"2.0","id":1,"method":"tools/call"}"#,
		#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":[]}"#,
		#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":7}}"#,
		#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"no_such_tool"}}"#,
		#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search_library"}}"#,
		#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search_library","arguments":"query"}}"#,
		#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search_library","arguments":{"query":7}}}"#,
		#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search_library","arguments":{"query":"","category":"nonsense"}}}"#,
		#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_library_entry","arguments":{"category":"../../etc","id":"passwd"}}}"#,
		#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"suggest_action","arguments":{"intent":"deleteEverything"}}}"#,
		#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":7}}"#,
		#"{"jsonrpc":"2.0","id":1,"method":"\#(String(repeating: "x", count: 100_000))"}"#,
		String(repeating: "[", count: 5000),
		String(repeating: "{\"a\":", count: 5000),
	]

	@Test(arguments: bodies)
	func anyBodyGetsAReplyOrNothing(body: String) async throws {
		let server = AskToolServer(tools: AskTools(catalog: Self.catalog))

		let reply = await server.respond(to: Data(body.utf8)) { _ in }

		guard !reply.isEmpty else { return }
		guard case let .object(object) = try JSONDecoder().decode(JSONValue.self, from: reply) else {
			Issue.record("Expected an object, found \(String(decoding: reply.prefix(200), as: UTF8.self))")
			return
		}
		#expect(object["jsonrpc"] == "2.0")
		#expect((object["result"] == nil) != (object["error"] == nil))
	}

	@Test(arguments: 0 ..< 300 as Range<UInt64>)
	func anyToolCallGetsAReply(seed: UInt64) async throws {
		var random = SeededRandom(seed: seed)
		let server = AskToolServer(tools: AskTools(catalog: Self.catalog))
		let names = ["search_library", "get_library_entry", "list_library", "suggest_action", "request_change_mode", "nonsense", ""]
		let keys = ["query", "category", "id", "tag", "intent", "mode", "reason", "title", "entry", "text", "limit"]
		let values: [JSONValue] = [
			"", "straw man", "fallacies", "straw-man", "debate", .null, 7, -1, true, [], [:], ["a", 1], .string(String(repeating: "é", count: 5000)),
			"'; DROP TABLE", "ergo://library/fallacies/straw-man", "\u{0}", "👨‍👩‍👧",
		]
		var arguments: [String: JSONValue] = [:]
		for _ in 0 ..< Int.random(in: 0 ... 5, using: &random) {
			try arguments[#require(keys.randomElement(using: &random))] = try #require(values.randomElement(using: &random))
		}
		let call: JSONValue = try [
			"jsonrpc": "2.0", "id": .number(Double(seed)), "method": "tools/call",
			"params": ["name": .string(#require(names.randomElement(using: &random))), "arguments": .object(arguments)],
		]

		let reply = try await server.respond(to: JSONEncoder().encode(call)) { _ in }

		guard case let .object(object) = try JSONDecoder().decode(JSONValue.self, from: reply) else {
			Issue.record("Expected an object")
			return
		}
		#expect(object["id"] == .number(Double(seed)))
		#expect((object["result"] == nil) != (object["error"] == nil))
	}

	// MARK: - Search

	@Test(arguments: ["", " ", "a", "the", "straw man", "STRAW MAN", "straw-man", "ad hominem ad hominem ad hominem", "é", "👨‍👩‍👧", "\u{0}", "%", ".*", "\\", String(repeating: "fallacy ", count: 2000)])
	func anySearchGivesAFewRealEntries(query: String) {
		for limit in [0, 1, 12] {
			let found = Self.catalog.search(query, limit: limit)
			#expect(found.count <= limit)
			#expect(Set(found.map { $0.category + "/" + $0.id }).count == found.count)
			#expect(found.allSatisfy { Self.catalog.entry(category: $0.category, id: $0.id) == $0 })
			#expect(found == Self.catalog.search(query, limit: limit))
		}
		for category in LibraryCatalog.categories + ["nonsense", ""] {
			#expect(Self.catalog.search(query, category: category).allSatisfy { $0.category == category })
		}
	}

	@Test func everyEntryIsFoundByItsOwnName() throws {
		let catalog = try #require(LibraryCatalog.shared)
		#expect(!catalog.entries.isEmpty)
		for entry in catalog.entries {
			let found = catalog.search(entry.name, category: entry.category, limit: 60)
			#expect(found.contains(entry), "\(entry.category)/\(entry.id)")
		}
	}

	// MARK: - A board chat

	/// The board as the device would have it after making every change it was told about
	struct Model {
		var cards: Set<UUID>
		var arrows: Set<[UUID]> = []

		mutating func apply(_ change: AskBoardEdit.Change) {
			switch change {
				case let .addCard(id, english, near):
					#expect(!cards.contains(id))
					#expect(!english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
					#expect(near.map(cards.contains) ?? true)
					cards.insert(id)
				case let .editCard(id, english):
					#expect(cards.contains(id))
					#expect(!english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
				case let .deleteCard(id):
					#expect(cards.contains(id))
					cards.remove(id)
					arrows = arrows.filter { !$0.contains(id) }
				case let .connect(premise, conclusion):
					#expect(cards.contains(premise) && cards.contains(conclusion) && premise != conclusion)
					#expect(!arrows.contains([premise, conclusion]))
					#expect(!reaches(conclusion, premise), "Expected no loop")
					arrows.insert([premise, conclusion])
				case let .disconnect(premise, conclusion):
					#expect(arrows.contains([premise, conclusion]))
					arrows.remove([premise, conclusion])
			}
		}

		func reaches(_ start: UUID, _ target: UUID) -> Bool {
			var seen: Set<UUID> = []
			var next = [start]
			while let current = next.popLast() {
				if current == target {
					return true
				}
				guard seen.insert(current).inserted else { continue }
				next += arrows.filter { $0[0] == current }.map { $0[1] }
			}
			return false
		}
	}

	static func board(canEdit: Bool, cards: [UUID]) -> AskBoard {
		AskBoard(
			title: "Weather",
			canEdit: canEdit,
			statements: cards.enumerated().map { .init(id: $1, english: "Claim \($0).") },
			links: [],
			sources: []
		)
	}

	@Test(arguments: 1000 ..< 1300 as Range<UInt64>)
	func whateverTheModelAsksTheBoardStillMakesSense(seed: UInt64) throws {
		var random = SeededRandom(seed: seed)
		let cards = (0 ..< Int.random(in: 1 ... 6, using: &random)).map { _ in UUID() }
		let tools = BoardChatTools(board: Self.board(canEdit: true, cards: cards), catalog: Self.catalog)
		var model = Model(cards: Set(cards))
		var added: [UUID] = []
		var edits: Set<UUID> = []

		for _ in 0 ..< 150 {
			let known = cards + added
			func id() -> JSONValue {
				switch Int.random(in: 0 ..< 10, using: &random) {
					case 0: .string(UUID().uuidString)
					case 1: "not an id"
					case 2: .string(known.randomElement(using: &random)!.uuidString.lowercased())
					case 3: 7
					default: .string(known.randomElement(using: &random)!.uuidString)
				}
			}
			let english: JSONValue = try #require(["Puddles formed.", "", "   ", .string(String(repeating: "long ", count: 400)), 7, .null].randomElement(using: &random))
			var arguments: [String: JSONValue] = [:]
			for (key, value) in [("id", id()), ("premise", id()), ("conclusion", id()), ("near", id()), ("english", english)] where Int.random(in: 0 ..< 5, using: &random) > 0 {
				arguments[key] = value
			}
			let name = try #require((BoardChatTools.names(canEdit: true) + ["nonsense"]).randomElement(using: &random))

			guard let reply = try? tools.reply(to: name, arguments: arguments), case let .boardEdit(edit)? = reply.event else { continue }

			#expect(edits.insert(edit.id).inserted, "Expected every change to have its own id")
			if case let .addCard(id, _, _) = edit.change {
				added.append(id)
			}
			model.apply(edit.change)
		}
	}

	@Test(arguments: 2000 ..< 2100 as Range<UInt64>)
	func aBoardThatCanOnlyBeViewedIsNeverChanged(seed: UInt64) throws {
		var random = SeededRandom(seed: seed)
		let cards = (0 ..< 4).map { _ in UUID() }
		let tools = BoardChatTools(board: Self.board(canEdit: false, cards: cards), catalog: Self.catalog)

		for _ in 0 ..< 60 {
			let arguments: [String: JSONValue] = try [
				"id": .string(#require(cards.randomElement(using: &random)?.uuidString)),
				"premise": .string(#require(cards.randomElement(using: &random)?.uuidString)),
				"conclusion": .string(#require(cards.randomElement(using: &random)?.uuidString)),
				"english": "Puddles formed.",
			]
			let name = try #require(BoardChatTools.names(canEdit: true).randomElement(using: &random))
			if case .boardEdit? = (try? tools.reply(to: name, arguments: arguments))?.event {
				Issue.record("Expected no change from \(name) on a board that can only be viewed")
			}
		}
	}
}

/// SplitMix64, so a seed that fails can be run again and fails the same way
private struct SeededRandom: RandomNumberGenerator {
	var state: UInt64

	init(seed: UInt64) {
		state = seed
	}

	mutating func next() -> UInt64 {
		state &+= 0x9E37_79B9_7F4A_7C15
		var z = state
		z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
		z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
		return z ^ (z >> 31)
	}
}
