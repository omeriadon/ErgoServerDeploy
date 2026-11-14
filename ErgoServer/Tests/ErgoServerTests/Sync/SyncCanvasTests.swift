//
//  SyncCanvasTests.swift
//  ErgoServer
//
//  Created by Adon Omeri on 6/11/2026.
//

import ErgoProtocol
@testable import ErgoServer
import Fluent
import Foundation
import Testing
import VaporTesting

/// The statement and link kinds on the server: conflicts per statement, the owning board, and pruning what a board leaves behind
struct SyncCanvasTests {
	static let day: Int64 = 86_400_000

	static func field(_ value: JSONValue, _ offset: Int64 = 0, device: String = "A") -> SyncField {
		SyncField(value: value, stamp: stamp(offset, device: device))
	}

	/// A board tombstone from before pruning's cutoff
	static func deletedBoard(_ id: String) -> SyncChange {
		let old = -100 * day
		return boardChange(id, [
			"created": field(1, old),
			"deleted": field(true, old + 1),
		])
	}

	static func statement(_ id: String, board: String?, _ english: String = "A claim", at offset: Int64 = 0) -> SyncChange {
		var fields = ["content": field(content(english), offset), "position": field(["x": 0, "y": 0], offset)]
		if let board {
			fields["board"] = field(.string(board), offset)
		}
		return statementChange(id, fields)
	}

	func keys(_ app: Application) async throws -> Set<SyncRecord.Key> {
		try await Set(SyncRecordRow.query(on: app.db).all().map(\.key))
	}

	// MARK: - Syncing

	@Test func recordsKeepTheirBoard() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let device = try await app.signedInAccount()
			let board = newBoardID()
			let (first, second, link) = (newBoardID(), newBoardID(), newBoardID())
			_ = try await app.sync(SyncRequest(cursor: nil, changes: [
				boardChange(board, ["created": Self.field(1)]),
				Self.statement(first, board: board),
				Self.statement(second, board: board),
				linkChange(link, board: board, premise: first, conclusion: second),
				SyncChange(kind: .bookmark, id: "fallacy.strawman", fields: ["present": Self.field(true)]),
			]), token: device.token)

			let rows = try await SyncRecordRow.query(on: app.db).all()
			let owners = Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0.board) })
			#expect(owners[SyncRecord.Key(kind: .statement, id: first)] == board)
			#expect(owners[SyncRecord.Key(kind: .link, id: link)] == board)
			#expect(owners[SyncRecord.Key(kind: .board, id: board)] == .some(nil))
			#expect(owners[SyncRecord.Key(kind: .bookmark, id: "fallacy.strawman")] == .some(nil))

			// Moving a statement to another board follows
			let other = newBoardID()
			_ = try await app.sync(SyncRequest(cursor: nil, changes: [
				statementChange(first, ["board": Self.field(.string(other), 1000)]),
			]), token: device.token)
			let moved = try #require(try await SyncRecordRow.find(SyncRecord.Key(kind: .statement, id: first), for: device.accountID, on: app.db))
			#expect(moved.board == other)
		}
	}

	/// Typing in one statement on two devices at once is a conflict for that statement only. Moving a box on one
	/// device while typing in it on another isn't a conflict at all.
	@Test func conflictsAreOneStatementsContent() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let phone = try await app.signedInAccount()
			let pad = try await app.signedInAccount()
			let board = newBoardID()
			let (first, second) = (newBoardID(), newBoardID())
			let base = Self.statement(first, board: board, "Base")
			let baseStamp = try #require(base.fields["content"]?.stamp)
			let positionStamp = try #require(base.fields["position"]?.stamp)
			_ = try await app.sync(SyncRequest(cursor: nil, changes: [base, Self.statement(second, board: board, "Other")]), token: phone.token)
			_ = try await app.sync(SyncRequest(cursor: nil, changes: []), token: pad.token)

			let phoneEdit = Self.field(content("From the phone"), 1000, device: "phone")
			let padEdit = Self.field(content("From the pad"), 2000, device: "pad")
			let moved = Self.field(["x": 40, "y": 80], 1500, device: "phone")
			let fromPhone = try await app.sync(SyncRequest(cursor: 2, changes: [
				statementChange(first, ["content": phoneEdit, "position": moved], bases: ["content": baseStamp, "position": positionStamp]),
			]), token: phone.token)
			#expect(fromPhone.superseded == [])

			let fromPad = try await app.sync(SyncRequest(cursor: 2, changes: [
				statementChange(first, ["content": padEdit], bases: ["content": baseStamp]),
				statementChange(second, ["content": Self.field(content("Pad's other"), 2000, device: "pad")], bases: ["content": positionStamp]),
			]), token: pad.token)

			// Only the first statement's content, and only the pad hears
			#expect(fromPad.superseded == [SupersededField(kind: .statement, id: first, field: "content", lost: phoneEdit)])
			let merged = try #require(fromPad.changes.first { $0.id == first })
			#expect(merged.fields["content"] == padEdit)
			#expect(merged.fields["position"] == moved)
		}
	}

	@Test func linksRoundTrip() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let phone = try await app.signedInAccount()
			let pad = try await app.signedInAccount()
			let board = newBoardID()
			let (premise, conclusion, link) = (newBoardID(), newBoardID(), newBoardID())
			let change = linkChange(link, board: board, premise: premise, conclusion: conclusion)
			_ = try await app.sync(SyncRequest(cursor: nil, changes: [change]), token: phone.token)

			let pulled = try await app.sync(SyncRequest(cursor: nil, changes: []), token: pad.token)
			#expect(pulled.changes == [change.record])
			#expect(pulled.changes.first?.joined?.premise == premise)
			#expect(pulled.changes.first?.owningBoard == board)
		}
	}

	// MARK: - Limits

	@Test func statementsAndLinksCountTowardTheLimit() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch)
		config.recordsPerAccount = 3

		try await withTestApp(config) { app in
			let device = try await app.signedInAccount()
			let board = newBoardID()
			let (first, second) = (newBoardID(), newBoardID())
			_ = try await app.sync(SyncRequest(cursor: nil, changes: [
				Self.statement(first, board: board),
				Self.statement(second, board: board),
				linkChange(newBoardID(), board: board, premise: first, conclusion: second),
			]), token: device.token)

			let (status, error) = try await app.syncRefusal(
				SyncRequest(cursor: nil, changes: [Self.statement(newBoardID(), board: board)]),
				token: device.token
			)
			#expect(status == .payloadTooLarge)
			#expect(error == ServiceError(code: .tooLarge, message: "Expected at most 3 synced records, found 4"))
			#expect(try await SyncRecordRow.query(on: app.db).count() == 3)

			// Editing one it has is still fine
			let edited = try await app.sync(SyncRequest(cursor: nil, changes: [Self.statement(first, board: board, "Edited", at: 1000)]), token: device.token)
			#expect(edited.changes.count == 3)
		}
	}

	@Test func theDefaultLimitFitsABigCanvas() throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		#expect(ServerConfig.testing(scratch).recordsPerAccount == 50000)
	}

	// MARK: - Pruning

	/// The board's tombstone goes, and its statements and links go with it even though they're recent
	@Test func deletedBoardsTakeTheirStatementsAndLinks() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let device = try await app.signedInAccount()
			let (gone, kept) = (newBoardID(), newBoardID())
			let (goneStatement, goneOther, goneLink) = (newBoardID(), newBoardID(), newBoardID())
			let (keptStatement, keptLink) = (newBoardID(), newBoardID())
			_ = try await app.sync(SyncRequest(cursor: nil, changes: [
				Self.deletedBoard(gone),
				Self.statement(goneStatement, board: gone),
				Self.statement(goneOther, board: gone),
				linkChange(goneLink, board: gone, premise: goneStatement, conclusion: goneOther),
				boardChange(kept, ["created": Self.field(1)]),
				Self.statement(keptStatement, board: kept),
				linkChange(keptLink, board: kept, premise: keptStatement, conclusion: keptStatement),
			]), token: device.token)

			#expect(try await app.ergo.sync.prune(on: app.db) == 4)
			#expect(try await app.ergo.sync.prune(on: app.db) == 0)
			#expect(try await keys(app) == [
				SyncRecord.Key(kind: .board, id: kept),
				SyncRecord.Key(kind: .statement, id: keptStatement),
				SyncRecord.Key(kind: .link, id: keptLink),
			])

			// Only the board's tombstone made a device start over, not the records it left
			let account = try #require(try await Account.find(device.accountID, on: app.db))
			#expect(account.prunedThrough == 1)
			#expect(account.seq == 7)
			let pulled = try await app.sync(SyncRequest(cursor: 1, changes: []), token: device.token)
			#expect(Set(pulled.changes.map(\.id)) == [kept, keptStatement, keptLink])
		}
	}

	/// A board deleted a day ago isn't pruned yet, so nothing it holds is
	@Test func recentlyDeletedBoardsKeepEverything() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let device = try await app.signedInAccount()
			let board = newBoardID()
			_ = try await app.sync(SyncRequest(cursor: nil, changes: [
				boardChange(board, ["created": Self.field(1, -2 * Self.day), "deleted": Self.field(true, -Self.day)]),
				Self.statement(newBoardID(), board: board),
			]), token: device.token)

			#expect(try await app.ergo.sync.prune(on: app.db) == 0)
			#expect(try await SyncRecordRow.query(on: app.db).count() == 2)
		}
	}

	/// Statements with no board record are kept for the same ninety days, since a board can arrive after its statements
	@Test func orphansWithNoBoardAreKeptThenPruned() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let device = try await app.signedInAccount()
			let alive = newBoardID()
			let missing = newBoardID()
			let (old, recent, noBoard, living, link) = (newBoardID(), newBoardID(), newBoardID(), newBoardID(), newBoardID())
			_ = try await app.sync(SyncRequest(cursor: nil, changes: [
				boardChange(alive, ["created": Self.field(1)]),
				Self.statement(old, board: missing),
				Self.statement(recent, board: missing),
				Self.statement(noBoard, board: nil),
				Self.statement(living, board: alive),
				linkChange(link, board: missing, premise: old, conclusion: recent),
			]), token: device.token)

			// Nothing's old enough yet
			#expect(try await app.ergo.sync.prune(on: app.db) == 0)

			for id in [old, noBoard, link] {
				let kind: SyncKind = id == link ? .link : .statement
				let row = try #require(try await SyncRecordRow.find(SyncRecord.Key(kind: kind, id: id), for: device.accountID, on: app.db))
				row.updated = .now - TimeInterval(100 * 24 * 60 * 60)
				try await row.save(on: app.db)
			}

			#expect(try await app.ergo.sync.prune(on: app.db) == 3)
			#expect(try await keys(app) == [
				SyncRecord.Key(kind: .board, id: alive),
				SyncRecord.Key(kind: .statement, id: recent),
				SyncRecord.Key(kind: .statement, id: living),
			])
			#expect(try await Account.find(device.accountID, on: app.db)?.prunedThrough == 0)
		}
	}

	/// A deleted statement is a tombstone like any other
	@Test func deletedStatementsArePrunedLikeBoards() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let device = try await app.signedInAccount()
			let board = newBoardID()
			let (deleted, alive) = (newBoardID(), newBoardID())
			let old = -100 * Self.day
			_ = try await app.sync(SyncRequest(cursor: nil, changes: [
				boardChange(board, ["created": Self.field(1, old)]),
				statementChange(deleted, [
					"board": Self.field(.string(board), old),
					"deleted": Self.field(true, old + 1),
				]),
				Self.statement(alive, board: board, at: old),
			]), token: device.token)

			#expect(try await app.ergo.sync.prune(on: app.db) == 1)
			#expect(try await keys(app) == [SyncRecord.Key(kind: .board, id: board), SyncRecord.Key(kind: .statement, id: alive)])
			#expect(try await Account.find(device.accountID, on: app.db)?.prunedThrough == 2)
		}
	}

	/// Pruning one account never touches another's
	@Test func pruningStaysWithinAnAccount() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let mine = try await app.signedInAccount()
			let theirs = try await app.signedInAccount("someone-else")
			let board = newBoardID()
			let statement = newBoardID()
			_ = try await app.sync(SyncRequest(cursor: nil, changes: [Self.deletedBoard(board), Self.statement(statement, board: board)]), token: mine.token)
			// The same board id on someone else's account is a different, living board
			_ = try await app.sync(SyncRequest(cursor: nil, changes: [
				boardChange(board, ["created": Self.field(1)]),
				Self.statement(statement, board: board),
			]), token: theirs.token)

			#expect(try await app.ergo.sync.prune(on: app.db) == 2)
			let remaining = try await SyncRecordRow.query(on: app.db).all()
			#expect(remaining.count == 2)
			#expect(remaining.allSatisfy { $0.$account.id == theirs.accountID })
		}
	}
}
