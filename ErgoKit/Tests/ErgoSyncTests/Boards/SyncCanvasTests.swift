//
//  SyncCanvasTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 6/11/2026.
//

import ErgoSync
import Foundation
import Testing

/// The statement and link kinds: what they may hold, a conflict copy per statement, and what a deleted board takes with it
struct SyncCanvasTests {
	static let boardID = "6F1C2E9A-3B4D-4E5F-8A9B-0C1D2E3F4A5B"
	static let statementID = "AAAAAAAA-2222-4333-8444-555555555555"
	static let otherStatementID = "BBBBBBBB-2222-4333-8444-555555555555"
	static let linkID = "CCCCCCCC-2222-4333-8444-555555555555"
	static let day: Int64 = 86_400_000

	static func content(_ english: String) -> JSONValue {
		["english": .string(english), "logic": [], "source": "english"]
	}

	static func position(_ x: Double, _ y: Double) -> JSONValue {
		["x": .number(x), "y": .number(y)]
	}

	/// Two devices holding a board with a statement on it, both caught up
	static func twoDevices() -> (FakeSyncServer, FakeDevice, FakeDevice) {
		var server = FakeSyncServer()
		var a = FakeDevice("A")
		var b = FakeDevice("B")
		a.syncUntilDone(with: &server)
		b.syncUntilDone(with: &server)
		a.edit(.board, boardID, ["created": 1], server)
		a.edit(.statement, statementID, ["board": .string(boardID), "position": position(0, 0), "content": content("base")], server)
		server.now += 1000
		a.syncUntilDone(with: &server)
		b.syncUntilDone(with: &server)
		return (server, a, b)
	}

	// MARK: - Kinds

	@Test func kindsKnowTheirFields() {
		#expect(SyncKind.known == [.board, .bookmark, .setting, .statement, .link, .scratchpad, .source])
		#expect(SyncKind.statement.fieldNames == ["board", "position", "content", "source", "deleted"])
		#expect(SyncKind.source.fieldNames == ["board", "position", "content", "deleted"])
		#expect(SyncKind.link.fieldNames == ["board", "premise", "conclusion", "deleted"])
		#expect(!SyncKind.board.fieldNames.contains(SyncFieldName.content))
		#expect(!SyncKind.board.fieldNames.contains("descriptor.5"))
		#expect(SyncKind.scratchpad.fieldNames.contains("descriptor.5"))
		#expect(SyncFieldName.content == "content")
	}

	@Test func statementAndLinkIDsAreUppercaseUUIDs() {
		for kind in [SyncKind.statement, .link, .source] {
			#expect(kind.isValid(id: Self.statementID))
			#expect(!kind.isValid(id: Self.statementID.lowercased()))
			#expect(!kind.isValid(id: "statement-1"))
			#expect(!kind.isValid(id: ""))
		}
	}

	@Test func aSourceGoesWithItsBoard() throws {
		let (server, a, _) = Self.twoDevices()
		var device = a
		device.edit(.source, Self.linkID, ["board": .string(Self.boardID), "position": Self.position(0, 0), "content": ["type": "text", "text": "A source"]], server)
		let source = try #require(device.replica[.source, Self.linkID])
		#expect(source.owningBoard == Self.boardID)
		#expect(!device.replica.isIgnored(source))

		device.edit(.board, Self.boardID, ["deleted": true], server)
		#expect(device.replica.isIgnored(source))
	}

	@Test func recordsPerAccountFitsBigBoards() {
		#expect(SyncLimit.recordsPerAccount == 50000)
	}

	// MARK: - Conflict copies

	/// Typing in one statement on two devices at once is a conflict for that statement only
	@Test func simultaneousContentGivesOneCopyOfThatStatement() throws {
		var (server, a, b) = Self.twoDevices()
		let id = Self.statementID
		a.edit(.statement, id, ["content": Self.content("from A")], server)
		b.edit(.statement, id, ["content": Self.content("from B")], server)
		server.now += 1000
		a.sync(with: &server)
		let synced = b.sync(with: &server)
		let applied = try #require(synced)
		a.syncUntilDone(with: &server)
		b.syncUntilDone(with: &server)

		let copies = applied.superseded(.statement, field: SyncFieldName.content)
		#expect(copies.count == 1)
		#expect(copies.first?.id == id)
		#expect(applied.superseded(.board, field: SyncFieldName.content) == [])
		#expect(a.superseded.isEmpty)
		#expect(a.replica.records == b.replica.records)
		#expect(a.replica[.statement, id]?.fields["content"]?.value == Self.content("from B"))
		#expect(copies.first?.lost.value == Self.content("from A"))
	}

	/// Dragging a box on one device while typing in it on another is no conflict: both fields are kept
	@Test func movingAndTypingDontClash() {
		var (server, a, b) = Self.twoDevices()
		let id = Self.statementID
		a.edit(.statement, id, ["position": Self.position(40, 80)], server)
		b.edit(.statement, id, ["content": Self.content("typed on B")], server)
		server.now += 1000
		a.syncUntilDone(with: &server)
		b.syncUntilDone(with: &server)
		a.syncUntilDone(with: &server)

		let merged = a.replica[.statement, id]?.values
		#expect(merged?["position"] == Self.position(40, 80))
		#expect(merged?["content"] == Self.content("typed on B"))
		#expect(a.superseded.isEmpty)
		#expect(b.superseded.isEmpty)
		#expect(a.replica.records == b.replica.records)
	}

	/// A statement's conflict doesn't touch the other statements on the board
	@Test func otherStatementsMergeCleanly() {
		var (server, a, b) = Self.twoDevices()
		a.edit(.statement, Self.otherStatementID, ["board": .string(Self.boardID), "content": Self.content("only A")], server)
		a.edit(.statement, Self.statementID, ["content": Self.content("from A")], server)
		b.edit(.statement, Self.statementID, ["content": Self.content("from B")], server)
		a.syncUntilDone(with: &server)
		b.syncUntilDone(with: &server)
		a.syncUntilDone(with: &server)

		let copied = (a.superseded + b.superseded).map(\.id)
		#expect(copied == [Self.statementID])
		#expect(b.replica[.statement, Self.otherStatementID]?.values["content"] == Self.content("only A"))
	}

	// MARK: - Ignoring

	@Test func statementsOfADeletedBoardAreIgnored() {
		var (server, a, b) = Self.twoDevices()
		a.edit(.link, Self.linkID, ["board": .string(Self.boardID), "premise": .string(Self.statementID), "conclusion": .string(Self.otherStatementID)], server)
		a.edit(.statement, Self.otherStatementID, ["board": .string(Self.boardID), "content": Self.content("conclusion")], server)
		a.syncUntilDone(with: &server)
		b.syncUntilDone(with: &server)
		#expect(b.replica.ignored == [])

		server.now += 1000
		a.edit(.board, Self.boardID, ["deleted": true], server)
		a.syncUntilDone(with: &server)
		b.syncUntilDone(with: &server)

		let ignored = SyncReplica.sorted([Self.statementID, Self.otherStatementID], [Self.linkID])
		#expect(b.replica.ignored == ignored)
		#expect(a.replica.ignored == ignored)

		// Undoing the delete is a newer `false`, and brings everything back
		server.now += 1000
		a.edit(.board, Self.boardID, ["deleted": false], server)
		a.syncUntilDone(with: &server)
		b.syncUntilDone(with: &server)
		#expect(b.replica.ignored == [])
	}

	@Test func linksNeedBothStatementsAndABoard() {
		var (server, a, _) = Self.twoDevices()
		let link = SyncRecord.Key(kind: .link, id: Self.linkID)
		a.edit(.link, Self.linkID, ["board": .string(Self.boardID), "premise": .string(Self.statementID), "conclusion": .string(Self.otherStatementID)], server)
		#expect(a.replica.ignored == [link], "The conclusion statement doesn't exist")

		a.edit(.statement, Self.otherStatementID, ["board": .string(Self.boardID), "content": Self.content("conclusion")], server)
		#expect(a.replica.ignored == [])

		server.now += 1000
		a.edit(.statement, Self.statementID, ["deleted": true], server)
		#expect(a.replica.ignored == [link], "A deleted statement takes its arrows out of play")

		a.edit(.link, Self.linkID, ["board": .string("not a board")], server)
		#expect(a.replica.ignored.contains(link))
	}

	@Test func otherKindsAreNeverIgnored() {
		let replica = SyncReplica(device: "A")
		for kind in [SyncKind.board, .bookmark, .setting, .scratchpad] {
			#expect(!replica.isIgnored(SyncRecord(kind: kind, id: "x")))
		}
		#expect(replica.isIgnored(SyncRecord(kind: .statement, id: Self.statementID)), "No board field yet")
	}

	// MARK: - Pruning

	/// The board's tombstone ages out on a device that stayed online, and takes the statements and links with it
	@Test func devicesPruneStatementsWithTheirBoard() {
		var (server, a, b) = Self.twoDevices()
		b.edit(.link, Self.linkID, ["board": .string(Self.boardID), "premise": .string(Self.statementID), "conclusion": .string(Self.statementID)], server)
		b.syncUntilDone(with: &server)
		a.syncUntilDone(with: &server)
		a.edit(.board, Self.boardID, ["deleted": true], server)
		a.syncUntilDone(with: &server)
		b.syncUntilDone(with: &server)

		server.now += (Int64(SyncLimit.tombstoneDays) + 1) * Self.day
		a.syncUntilDone(with: &server)
		server.prune()
		b.syncUntilDone(with: &server)

		#expect(a.replica.records.isEmpty)
		#expect(b.replica.records.isEmpty)
		#expect(server.records.isEmpty)
	}

	/// After a reset a device pushes back what the server lacks, but not what the server dropped with a board
	@Test func resetsDontBringOrphansBack() {
		var (server, a, b) = Self.twoDevices()
		a.edit(.board, Self.boardID, ["deleted": true], server)
		a.syncUntilDone(with: &server)
		b.syncUntilDone(with: &server)
		server.prune()
		#expect(server.records.isEmpty)

		for _ in 0 ..< 2 {
			b.syncUntilDone(with: &server)
			a.syncUntilDone(with: &server)
		}
		#expect(server.records[SyncRecord.Key(kind: .statement, id: Self.statementID)] == nil)
		#expect(b.replica.isCaughtUp)
	}

	// MARK: - First sign-in

	/// What's on a device when it first signs in goes up whole, however the seeds happen to be ordered
	@Test func firstSyncPushesEveryStatementAndLink() {
		var server = FakeSyncServer()
		var device = FakeDevice("A")
		let statements = (0 ..< 30).map { _ in UUID().uuidString }
		let links = (0 ..< 29).map { _ in UUID().uuidString }

		device.edit(.board, Self.boardID, ["created": 1], server)
		for id in statements {
			device.edit(.statement, id, ["board": .string(Self.boardID), "position": Self.position(0, 0), "content": Self.content(id)], server)
		}
		for (index, id) in links.enumerated() {
			device.edit(.link, id, ["board": .string(Self.boardID), "premise": .string(statements[index]), "conclusion": .string(statements[index + 1])], server)
		}
		device.syncUntilDone(with: &server)

		#expect(server.records.values.count { $0.kind == .board } == 1)
		#expect(server.records.values.count { $0.kind == .statement } == statements.count)
		#expect(server.records.values.count { $0.kind == .link } == links.count)
		#expect(device.replica.ignored.isEmpty)
		#expect(device.replica.pending.isEmpty)
	}

	/// A statement seeded on a board the server has deleted is what deleting the board was meant to remove
	@Test func firstSyncLeavesStatementsOfADeletedBoardDown() {
		var (server, a, _) = Self.twoDevices()
		a.edit(.board, Self.boardID, ["deleted": true], server)
		server.now += 1000
		a.syncUntilDone(with: &server)

		var fresh = FakeDevice("C")
		fresh.edit(.statement, Self.otherStatementID, ["board": .string(Self.boardID), "position": Self.position(0, 0), "content": Self.content("seed")], server)
		fresh.syncUntilDone(with: &server)

		#expect(server.records[SyncRecord.Key(kind: .statement, id: Self.otherStatementID)] == nil)
	}

	/// A push too big for one request reaches other devices part way through, and they delete a link whose statement
	/// looks gone. So links always go up after the statements they join.
	@Test func linksGoUpAfterTheirStatements() {
		var server = FakeSyncServer()
		var device = FakeDevice("A")
		device.syncUntilDone(with: &server)

		device.edit(.board, Self.boardID, ["created": 1], server)
		let words = String(repeating: "a", count: SyncLimit.valueBytes / 2)
		let statements = (0 ..< 8).map { _ in UUID().uuidString }
		for id in statements {
			device.edit(.statement, id, ["board": .string(Self.boardID), "content": ["english": .string(words)]], server)
		}
		device.edit(.link, Self.linkID, ["board": .string(Self.boardID), "premise": .string(statements[0]), "conclusion": .string(statements[1])], server)

		var sent: [SyncKind] = []
		for _ in 0 ..< 20 {
			sent += device.replica.makeRequest().changes.map(\.kind)
			guard let applied = device.sync(with: &server), applied.syncAgain else { break }
		}

		#expect(sent.first == .board)
		#expect(sent.last == .link)
		#expect(sent.count { $0 == .statement } == statements.count)
	}
}

private extension SyncReplica {
	/// The keys of these statements and links, in the order `ignored` lists them
	static func sorted(_ statements: [String], _ links: [String]) -> [SyncRecord.Key] {
		(links.map { SyncRecord.Key(kind: .link, id: $0) } + statements.map { SyncRecord.Key(kind: .statement, id: $0) }).sorted()
	}
}
