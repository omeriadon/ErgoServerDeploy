//
//  SyncTests.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoProtocol
@testable import ErgoServer
import Fluent
import Foundation
import SQLKit
import Testing
import VaporTesting

// MARK: - Helpers

extension Application {
	func sync(_ request: SyncRequest, token: String) async throws -> SyncResponse {
		var synced: SyncResponse?
		try await testing().test(.POST, ErgoProtocol.Path.sync, headers: .signedIn(token), body: body(request)) { response async throws in
			#expect(response.status == .ok)
			if response.status != .ok {
				try Issue.record("Expected a sync response, found \(response.decoded(ServiceError.self))")
			}
			synced = try? response.decoded(SyncResponse.self)
		}
		return try #require(synced)
	}

	/// The refusal, and its status
	func syncRefusal(_ request: SyncRequest, token: String) async throws -> (HTTPResponseStatus, ServiceError) {
		var refusal: (HTTPResponseStatus, ServiceError)?
		try await testing().test(.POST, ErgoProtocol.Path.sync, headers: .signedIn(token), body: body(request)) { response async throws in
			refusal = try (response.status, response.decoded(ServiceError.self))
		}
		return try #require(refusal)
	}
}

/// Stamps around the server's clock, in milliseconds
func stamp(_ offset: Int64 = 0, counter: Int = 0, device: String = "A") -> SyncStamp {
	SyncStamp(time: Int64(Date.now.timeIntervalSince1970 * 1000) + offset, counter: counter, device: device)
}

func content(_ english: String) -> JSONValue {
	["english": .string(english), "logic": [], "source": "english"]
}

func boardChange(_ id: String, _ fields: [String: SyncField], bases: [String: SyncStamp] = [:]) -> SyncChange {
	SyncChange(kind: .board, id: id, fields: fields, bases: bases)
}

func statementChange(_ id: String, _ fields: [String: SyncField], bases: [String: SyncStamp] = [:]) -> SyncChange {
	SyncChange(kind: .statement, id: id, fields: fields, bases: bases)
}

func scratchpadChange(_ id: String, _ fields: [String: SyncField], bases: [String: SyncStamp] = [:]) -> SyncChange {
	SyncChange(kind: .scratchpad, id: id, fields: fields, bases: bases)
}

func linkChange(_ id: String, board: String, premise: String, conclusion: String, at stamp: SyncStamp = stamp()) -> SyncChange {
	SyncChange(kind: .link, id: id, fields: [
		"board": SyncField(value: .string(board), stamp: stamp),
		"premise": SyncField(value: .string(premise), stamp: stamp),
		"conclusion": SyncField(value: .string(conclusion), stamp: stamp),
	])
}

func newBoardID() -> String {
	UUID().uuidString
}

// MARK: - Tests

struct SyncTests {
	@Test func twoDevicesOnOneAccount() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let phone = try await app.signedInAccount()
			let pad = try await app.signedInAccount()
			#expect(pad.accountID == phone.accountID)
			#expect(!pad.isNewAccount)

			// The phone writes a statement, the iPad pulls it
			let board = newBoardID()
			let first = SyncField(value: content("It's raining, so the ground is wet."), stamp: stamp(device: "phone"))
			let pushed = try await app.sync(SyncRequest(cursor: nil, changes: [statementChange(board, ["content": first])]), token: phone.token)
			#expect(pushed.cursor == 1)
			#expect(pushed.superseded == [])

			let pulled = try await app.sync(SyncRequest(cursor: nil, changes: []), token: pad.token)
			#expect(pulled.changes == [SyncRecord(kind: .statement, id: board, fields: ["content": first])])
			#expect(pulled.cursor == 1)
			#expect(!pulled.more)
			#expect(abs(pulled.serverTime.timeIntervalSinceNow) < 5)

			// Both edit from that, the phone first. The iPad's later edit wins, and only the iPad hears what lost.
			let phoneEdit = SyncField(value: content("Phone"), stamp: stamp(1, device: "phone"))
			let padEdit = SyncField(value: content("iPad"), stamp: stamp(2, device: "pad"))
			let fromPhone = try await app.sync(
				SyncRequest(cursor: 1, changes: [statementChange(board, ["content": phoneEdit], bases: ["content": first.stamp])]),
				token: phone.token
			)
			#expect(fromPhone.superseded == [])

			let fromPad = try await app.sync(
				SyncRequest(cursor: 1, changes: [statementChange(board, ["content": padEdit], bases: ["content": first.stamp])]),
				token: pad.token
			)
			#expect(fromPad.superseded == [SupersededField(kind: .statement, id: board, field: "content", lost: phoneEdit)])
			#expect(fromPad.changes.map(\.fields) == [["content": padEdit]])
			#expect(fromPad.cursor == 3)

			let caughtUp = try await app.sync(SyncRequest(cursor: fromPhone.cursor, changes: []), token: phone.token)
			#expect(caughtUp.changes.map(\.fields) == [["content": padEdit]])
			#expect(caughtUp.superseded == [])
		}
	}

	@Test func sameValueTwiceChangesNothing() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let device = try await app.signedInAccount()
			let change = SyncChange(kind: .setting, id: "ditherEnabled", fields: ["value": SyncField(value: true, stamp: stamp())])

			let first = try await app.sync(SyncRequest(cursor: nil, changes: [change]), token: device.token)
			let again = try await app.sync(SyncRequest(cursor: first.cursor, changes: [change]), token: device.token)
			#expect(first.cursor == 1)
			#expect(again.cursor == 1)
			#expect(again.changes == [])
		}
	}

	@Test func boardsWithMore() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let device = try await app.signedInAccount()
			let changes = (0 ..< 5).map { index in
				SyncChange(kind: .bookmark, id: "fallacy-\(index)", fields: ["present": SyncField(value: true, stamp: stamp(Int64(index)))])
			}
			_ = try await app.sync(SyncRequest(cursor: nil, changes: changes), token: device.token)

			var cursor: Int?
			var boards: [[String]] = []
			var cursors: [Int] = []
			while true {
				let response = try await app.sync(SyncRequest(cursor: cursor, changes: [], limit: 2), token: device.token)
				boards.append(response.changes.map(\.id))
				cursors.append(response.cursor)
				cursor = response.cursor
				if !response.more {
					break
				}
			}
			#expect(boards == [["fallacy-0", "fallacy-1"], ["fallacy-2", "fallacy-3"], ["fallacy-4"]])
			#expect(cursors == [2, 4, 5])

			// Exactly a board left still says no more
			let last = try await app.sync(SyncRequest(cursor: 3, changes: [], limit: 2), token: device.token)
			#expect(last.changes.map(\.id) == ["fallacy-3", "fallacy-4"])
			#expect(!last.more)
			#expect(last.cursor == 5)
		}
	}

	// MARK: - Refusing

	@Test func anonymousAccountsMustSignIn() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let account = try await app.createAccount()
			let (status, error) = try await app.syncRefusal(SyncRequest(cursor: nil, changes: []), token: account.token)
			#expect(status == .forbidden)
			#expect(error == ServiceError(code: .signInRequired, message: "Sign in to sync"))
			#expect(try await SyncRecordRow.query(on: app.db).count() == 0)
		}
	}

	@Test(arguments: [
		(
			SyncChange(kind: "note", id: "1", fields: [:]),
			"Unknown record kind 'note', expected 'board', 'bookmark', 'setting', 'statement', 'link' or 'scratchpad'"
		),
		(
			SyncChange(kind: .board, id: "not-a-uuid", fields: [:]),
			"Expected a board id to be an uppercase UUID, found 'not-a-uuid'"
		),
		(
			SyncChange(kind: .board, id: UUID().uuidString.lowercased(), fields: [:]),
			"Expected a board id to be an uppercase UUID"
		),
		(
			SyncChange(kind: .setting, id: "translationServer", fields: [:]),
			"Unknown setting 'translationServer'"
		),
		(
			SyncChange(kind: .board, id: UUID().uuidString, fields: ["title": SyncField(value: "Hi", stamp: stamp())]),
			"Unknown field 'title' in a board record"
		),
		(
			SyncChange(kind: .bookmark, id: "", fields: [:]),
			"Expected a bookmark id of 1 to 256 bytes, found 0"
		),
		// Boards no longer carry content, statements do
		(
			SyncChange(kind: .board, id: UUID().uuidString, fields: ["content": SyncField(value: content("Hi"), stamp: stamp())]),
			"Unknown field 'content' in a board record"
		),
		// Descriptors are per scratchpad, not per board
		(
			SyncChange(kind: .board, id: UUID().uuidString, fields: ["descriptor.0": SyncField(value: "rain", stamp: stamp())]),
			"Unknown field 'descriptor.0' in a board record"
		),
		(
			SyncChange(kind: .statement, id: UUID().uuidString, fields: ["english": SyncField(value: "Hi", stamp: stamp())]),
			"Unknown field 'english' in a statement record"
		),
		(
			SyncChange(kind: .statement, id: UUID().uuidString, fields: ["descriptor.0": SyncField(value: "rain", stamp: stamp())]),
			"Unknown field 'descriptor.0' in a statement record"
		),
		(
			SyncChange(kind: .link, id: UUID().uuidString, fields: ["content": SyncField(value: content("Hi"), stamp: stamp())]),
			"Unknown field 'content' in a link record"
		),
		(
			SyncChange(kind: .link, id: UUID().uuidString, fields: ["position": SyncField(value: ["x": 0, "y": 0], stamp: stamp())]),
			"Unknown field 'position' in a link record"
		),
		(
			SyncChange(kind: .statement, id: "statement-1", fields: [:]),
			"Expected a statement id to be an uppercase UUID, found 'statement-1'"
		),
		(
			SyncChange(kind: .link, id: UUID().uuidString.lowercased(), fields: [:]),
			"Expected a link id to be an uppercase UUID"
		),
	])
	func malformedChanges(change: SyncChange, message: String) async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let device = try await app.signedInAccount()
			let (status, error) = try await app.syncRefusal(SyncRequest(cursor: nil, changes: [change]), token: device.token)
			#expect(status == .badRequest)
			#expect(error.code == .invalidRequest)
			#expect(error.message.hasPrefix(message))
		}
	}

	@Test func futureStampsAreRefused() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let device = try await app.signedInAccount()
			let ahead = stamp(SyncLimit.futureStamp + 60000)
			let change = statementChange(newBoardID(), ["content": SyncField(value: content("From the future"), stamp: ahead)])

			let (status, error) = try await app.syncRefusal(SyncRequest(cursor: nil, changes: [change]), token: device.token)
			#expect(status == .badRequest)
			#expect(error == ServiceError(code: .invalidRequest, message: "Expected a time within 10 minutes of the server, found 11 minutes ahead"))

			// A little ahead is just clock skew
			let skewed = statementChange(newBoardID(), ["content": SyncField(value: content("Fine"), stamp: stamp(60000))])
			#expect(try await app.sync(SyncRequest(cursor: nil, changes: [skewed]), token: device.token).cursor == 1)
		}
	}

	@Test func bigValuesAreRefused() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let device = try await app.signedInAccount()
			let english = String(repeating: "a", count: 300 * 1024)
			let change = statementChange(newBoardID(), ["content": SyncField(value: content(english), stamp: stamp())])

			let (status, error) = try await app.syncRefusal(SyncRequest(cursor: nil, changes: [change]), token: device.token)
			#expect(status == .payloadTooLarge)
			#expect(error == ServiceError(code: .tooLarge, message: "Expected a statement under 256 KB, found 301 KB"))

			// Over the limit is over the limit for every field
			let descriptor = scratchpadChange(newBoardID(), ["descriptor.0": SyncField(value: .string(english), stamp: stamp())])
			let (_, descriptorError) = try await app.syncRefusal(SyncRequest(cursor: nil, changes: [descriptor]), token: device.token)
			#expect(descriptorError.code == .tooLarge)

			// Just under is fine
			let small = String(repeating: "a", count: 200 * 1024)
			let fits = statementChange(newBoardID(), ["content": SyncField(value: content(small), stamp: stamp())])
			#expect(try await app.sync(SyncRequest(cursor: nil, changes: [fits]), token: device.token).cursor == 1)
		}
	}

	@Test func bigBodiesAreRefused() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let device = try await app.signedInAccount()
			let changes = (0 ..< 5).map { _ in
				statementChange(newBoardID(), ["content": SyncField(value: content(String(repeating: "a", count: 250 * 1024)), stamp: stamp())])
			}

			let (status, error) = try await app.syncRefusal(SyncRequest(cursor: nil, changes: changes), token: device.token)
			#expect(status == .payloadTooLarge)
			#expect(error.code == .tooLarge)
			#expect(error.message.hasPrefix("Expected a sync under 1 MB, found 12"))
			#expect(try await SyncRecordRow.query(on: app.db).count() == 0)
		}
	}

	@Test func recordCountIsLimited() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch)
		config.recordsPerAccount = 3

		try await withTestApp(config) { app in
			let device = try await app.signedInAccount()
			let bookmark = { (id: String, present: Bool) in
				SyncChange(kind: .bookmark, id: id, fields: ["present": SyncField(value: .bool(present), stamp: stamp(present ? 0 : 1000))])
			}
			_ = try await app.sync(SyncRequest(cursor: nil, changes: [bookmark("a", true), bookmark("b", true)]), token: device.token)

			let (status, error) = try await app.syncRefusal(
				SyncRequest(cursor: nil, changes: [bookmark("c", true), bookmark("d", true)]),
				token: device.token
			)
			#expect(status == .payloadTooLarge)
			#expect(error == ServiceError(code: .tooLarge, message: "Expected at most 3 synced records, found 4"))
			// All or nothing
			#expect(try await SyncRecordRow.query(on: app.db).count() == 2)

			// Changing records it already has is still fine
			let changed = try await app.sync(SyncRequest(cursor: nil, changes: [bookmark("a", false), bookmark("c", true)]), token: device.token)
			#expect(changed.changes.map(\.id) == ["b", "a", "c"])
		}
	}

	@Test func syncsAreRateLimited() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch)
		config.syncsPerMinute = 2

		try await withTestApp(config) { app in
			let device = try await app.signedInAccount()
			let other = try await app.signedInAccount("someone-else")
			_ = try await app.sync(SyncRequest(cursor: nil, changes: []), token: device.token)
			_ = try await app.sync(SyncRequest(cursor: nil, changes: []), token: device.token)

			let (status, error) = try await app.syncRefusal(SyncRequest(cursor: nil, changes: []), token: device.token)
			#expect(status == .tooManyRequests)
			#expect(error == ServiceError(code: .rateLimited, message: "Too many syncs from this account, try again in a minute"))
			_ = try await app.sync(SyncRequest(cursor: nil, changes: []), token: other.token)
		}
	}

	@Test func limiterForgetsAfterAMinute() {
		let limits = SyncLimits(requestsPerMinute: 1)
		let account = UUID()
		let start = Date.now

		#expect(limits.allow(account, now: start))
		#expect(!limits.allow(account, now: start + 30))
		#expect(limits.allow(UUID(), now: start + 30))
		#expect(limits.allow(account, now: start + 61))
	}

	// MARK: - Pruning

	@Test func pruningNeedsAReset() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let device = try await app.signedInAccount()
			let old: Int64 = -100 * 24 * 60 * 60 * 1000
			let deleted = newBoardID()
			let recent = newBoardID()
			let alive = newBoardID()

			_ = try await app.sync(SyncRequest(cursor: nil, changes: [
				boardChange(deleted, [
					"created": SyncField(value: 1, stamp: stamp(old)),
					"deleted": SyncField(value: true, stamp: stamp(old + 1)),
				]),
				boardChange(recent, [
					"created": SyncField(value: 1, stamp: stamp(-1000)),
					"deleted": SyncField(value: true, stamp: stamp()),
				]),
				boardChange(alive, ["created": SyncField(value: 1, stamp: stamp(old))]),
			]), token: device.token)

			#expect(try await app.ergo.sync.prune(on: app.db) == 1)
			#expect(try await app.ergo.sync.prune(on: app.db) == 0)
			let account = try #require(try await Account.find(device.accountID, on: app.db))
			#expect(account.prunedThrough == 1)
			#expect(account.seq == 3)

			let (status, error) = try await app.syncRefusal(SyncRequest(cursor: 0, changes: []), token: device.token)
			#expect(status == .gone)
			#expect(error.code == .syncResetRequired)

			// From the start, or from after the pruned one, is fine
			#expect(try await app.sync(SyncRequest(cursor: nil, changes: []), token: device.token).changes.map(\.id) == [recent, alive])
			#expect(try await app.sync(SyncRequest(cursor: 1, changes: []), token: device.token).changes.map(\.id) == [recent, alive])
		}
	}

	@Test func cursorAheadOfTheServerNeedsAReset() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let device = try await app.signedInAccount()
			let (status, error) = try await app.syncRefusal(SyncRequest(cursor: 7, changes: []), token: device.token)
			#expect(status == .gone)
			#expect(error == ServiceError(code: .syncResetRequired, message: "Expected a cursor up to 0, found 7"))
		}
	}

	// MARK: - At rest

	@Test func fieldsAreSealedAtRest() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let device = try await app.signedInAccount()
			let english = "Socrates is a man, and all men are mortal"
			let board = newBoardID()
			_ = try await app.sync(SyncRequest(cursor: nil, changes: [
				statementChange(board, ["content": SyncField(value: content(english), stamp: stamp()), "board": SyncField(value: .string(newBoardID()), stamp: stamp())]),
			]), token: device.token)

			let sql = try #require(app.db as? any SQLDatabase)
			let rows = try await sql.raw("SELECT fields, kind, record_id FROM sync_records").all()
			#expect(rows.count == 1)
			let sealed = try #require(rows.first).decode(column: "fields", as: Data.self)
			let raw = String(decoding: sealed, as: UTF8.self)
			#expect(!raw.contains("Socrates"))
			#expect(!raw.contains("mortal"))

			// Opens only as its own row
			let row = try #require(try await SyncRecordRow.find(SyncRecord.Key(kind: .statement, id: board), for: device.accountID, on: app.db))
			#expect(try row.record(app.ergo.vault).fields["content"]?.value == content(english))
			#expect(throws: CredentialVault.Unreadable.self) {
				try app.ergo.vault.open(sealed, account: device.accountID, record: SyncRecord.Key(kind: .statement, id: newBoardID()))
			}
			#expect(throws: CredentialVault.Unreadable.self) {
				try app.ergo.vault.open(sealed, account: UUID(), record: row.key)
			}
		}
	}
}
