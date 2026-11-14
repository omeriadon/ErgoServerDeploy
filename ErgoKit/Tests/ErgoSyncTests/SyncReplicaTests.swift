//
//  SyncReplicaTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoSync
import Foundation
import Testing

struct SyncReplicaTests {
	static let boardID = "6F1C2E9A-3B4D-4E5F-8A9B-0C1D2E3F4A5B"
	static let otherBoardID = "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"
	static let board = SyncRecord.Key(kind: .board, id: boardID)
	static let letters = SyncRecord.Key(kind: .setting, id: SyncedSetting.logicLetters.rawValue)

	/// Two devices on one server, both caught up and holding the same board
	static func twoDevices(content: JSONValue = "base") -> (FakeSyncServer, FakeDevice, FakeDevice) {
		var server = FakeSyncServer()
		var a = FakeDevice("A")
		var b = FakeDevice("B")
		a.syncUntilDone(with: &server)
		b.syncUntilDone(with: &server)
		a.edit(.board, boardID, ["content": content], server)
		server.now += 1000
		a.syncUntilDone(with: &server)
		b.syncUntilDone(with: &server)
		return (server, a, b)
	}

	// MARK: - Local changes

	@Test func unchangedValuesRecordNothing() throws {
		var server = FakeSyncServer()
		var device = FakeDevice("A")
		device.syncUntilDone(with: &server)

		let recorded = device.edit(.board, Self.boardID, ["content": "a", "descriptor.0": "rain"], server)
		#expect(recorded)
		let recordedAgain = device.edit(.board, Self.boardID, ["content": "a", "descriptor.0": "rain"], server)
		#expect(!recordedAgain)
		#expect(device.replica.pending[Self.board]?.fields.keys.sorted() == ["content", "descriptor.0"])

		device.syncUntilDone(with: &server)
		#expect(device.replica.pending.isEmpty)
		let recordedAfterSync = device.edit(.board, Self.boardID, ["content": "a", "descriptor.0": "rain"], server)
		#expect(!recordedAfterSync)

		let base = device.replica[.board, Self.boardID]?.fields["content"]?.stamp
		server.now += 1000
		let recordedEdit = device.edit(.board, Self.boardID, ["content": "ab", "descriptor.0": "rain"], server)
		#expect(recordedEdit)
		#expect(device.replica.pending[Self.board]?.fields.keys.sorted() == ["content"])
		#expect(try device.replica.pending[Self.board]?.bases == ["content": #require(base)])
	}

	/// Writing a remote change back and reporting it again is what would cause an echo loop
	@Test func reportingARemoteChangeBackRecordsNothing() throws {
		var (server, a, b) = Self.twoDevices()
		server.now += 1000
		a.edit(.board, Self.boardID, ["content": "from A", "descriptor.1": "snow"], server)
		a.syncUntilDone(with: &server)

		let synced = b.sync(with: &server)
		let applied = try #require(synced)
		let record = try #require(applied.changed.first)
		#expect(applied.changed.count == 1)
		#expect(record.values == ["content": "from A", "descriptor.1": "snow"])
		let echoed = b.edit(.board, Self.boardID, record.values, server)
		#expect(!echoed)
		#expect(b.replica.pending.isEmpty)
	}

	// MARK: - Requests

	@Test func nothingIsPushedBeforeTheClockHasAServerTime() {
		var server = FakeSyncServer()
		var device = FakeDevice("A", skew: 90000)
		device.edit(.setting, SyncedSetting.logicLetters.rawValue, ["value": ["P", "Q"]], server)

		let first = device.replica.makeRequest()
		#expect(first.cursor == nil)
		#expect(first.changes.isEmpty)
		let firstSync = device.sync(with: &server)
		#expect(firstSync?.syncAgain == true)

		device.syncUntilDone(with: &server)
		#expect(server.records[Self.letters]?.values == ["value": ["P", "Q"]])
		#expect(device.replica.isCaughtUp)
	}

	@Test func typingDuringARequestStaysPending() throws {
		var server = FakeSyncServer()
		var device = FakeDevice("A")
		device.syncUntilDone(with: &server)
		device.edit(.board, Self.boardID, ["content": "a"], server)

		let request = device.replica.makeRequest()
		let response = try server.sync(request)
		server.now += 100
		device.edit(.board, Self.boardID, ["content": "ab"], server)
		let applied = device.replica.apply(response, sent: request, at: device.now(server))

		#expect(applied.changed.isEmpty)
		#expect(applied.syncAgain)
		#expect(device.replica.pending[Self.board]?.fields["content"]?.value == "ab")
		#expect(device.replica.pending[Self.board]?.bases["content"] == request.changes.first?.fields["content"]?.stamp)

		device.syncUntilDone(with: &server)
		#expect(device.replica.pending.isEmpty)
		#expect(server.records[Self.board]?.values == ["content": "ab"])
		#expect(device.superseded.isEmpty)
	}

	@Test func oversizedValuesStayOnTheDevice() {
		var server = FakeSyncServer()
		var device = FakeDevice("A")
		device.syncUntilDone(with: &server)
		device.edit(.board, Self.boardID, ["content": .string(String(repeating: "a", count: SyncLimit.valueBytes))], server)
		device.edit(.board, Self.otherBoardID, ["content": "small"], server)

		let request = device.replica.makeRequest()
		#expect(request.changes.map(\.id) == [Self.otherBoardID])
		#expect(device.replica.oversized == [Self.board])

		device.syncUntilDone(with: &server)
		#expect(server.records[Self.board] == nil)
		#expect(device.replica.pending.keys.sorted() == [Self.board])
	}

	@Test func bigPushesAreSplitUnderTheBodyLimit() throws {
		var server = FakeSyncServer()
		var device = FakeDevice("A")
		device.syncUntilDone(with: &server)
		let ids = (0 ..< 6).map { _ in UUID().uuidString }
		for id in ids {
			device.edit(.board, id, ["content": .string(String(repeating: "a", count: 200_000))], server)
		}

		var requests = 0
		while !device.replica.pending.isEmpty, requests < 10 {
			let request = device.replica.makeRequest()
			#expect(try JSONEncoder().encode(request).count < SyncLimit.requestBytes)
			_ = try device.replica.apply(server.sync(request), sent: request, at: device.now(server))
			requests += 1
		}
		#expect(requests == 2)
		#expect(Set(server.records.keys.map(\.id)) == Set(ids))
	}

	// MARK: - Responses

	@Test func pagingPullsEverything() {
		var server = FakeSyncServer()
		var a = FakeDevice("A")
		a.syncUntilDone(with: &server)
		for _ in 0 ..< 10 {
			a.edit(.board, UUID().uuidString, ["content": "a"], server)
		}
		a.syncUntilDone(with: &server)

		var b = FakeDevice("B")
		let firstBoard = b.sync(with: &server, limit: 3)
		#expect(firstBoard?.syncAgain == true)
		#expect(!b.replica.isCaughtUp)
		b.syncUntilDone(with: &server, limit: 3)
		#expect(b.replica.isCaughtUp)
		#expect(b.replica.records == a.replica.records)
		#expect(b.replica.cursor == server.seq)
	}

	@Test func aResponseFromBeforeAResetDoesntMoveTheCursor() throws {
		var (server, a, _) = Self.twoDevices()
		let request = a.replica.makeRequest()
		let response = try server.sync(request)
		a.replica.reset()
		_ = a.replica.apply(response, sent: request, at: a.now(server))

		#expect(a.replica.cursor == nil)
		#expect(!a.replica.isCaughtUp)
	}

	// MARK: - Conflicts

	/// Two devices edit a board offline: one copy is made, by the device that pushed second, and nothing disappears
	@Test(arguments: [false, true])
	func concurrentContentEditsGiveOneSuperseded(firstPusherEditsLater: Bool) {
		var (server, a, b) = Self.twoDevices()
		server.now += 1000
		if firstPusherEditsLater {
			b.edit(.board, Self.boardID, ["content": "from B"], server)
			server.now += 1000
			a.edit(.board, Self.boardID, ["content": "from A"], server)
		} else {
			a.edit(.board, Self.boardID, ["content": "from A"], server)
			server.now += 1000
			b.edit(.board, Self.boardID, ["content": "from B"], server)
		}
		for _ in 0 ..< 2 {
			a.syncUntilDone(with: &server)
			b.syncUntilDone(with: &server)
		}

		let winner: JSONValue = firstPusherEditsLater ? "from A" : "from B"
		let loser: JSONValue = firstPusherEditsLater ? "from B" : "from A"
		#expect(a.superseded.isEmpty)
		#expect(b.superseded.map(\.lost.value) == [loser])
		#expect(b.superseded.first?.field == "content")
		#expect(server.records[Self.board]?.values == ["content": winner])
		#expect(a.replica.records == server.records)
		#expect(b.replica.records == server.records)
	}

	/// The server never saw the beaten typing, so only the replica can catch it
	@Test func unsentTypingBeatenByARemoteEditIsSuperseded() throws {
		var (server, a, b) = Self.twoDevices()
		let request = b.replica.makeRequest()
		server.now += 1000
		b.edit(.board, Self.boardID, ["content": "from B"], server)
		server.now += 1000
		a.edit(.board, Self.boardID, ["content": "from A"], server)
		a.syncUntilDone(with: &server)

		let applied = try b.replica.apply(server.sync(request), sent: request, at: b.now(server))
		#expect(applied.superseded.map(\.lost.value) == ["from B"])
		#expect(applied.changed.map(\.values) == [["content": "from A"]])
		#expect(b.replica.pending.isEmpty)

		b.syncUntilDone(with: &server)
		a.syncUntilDone(with: &server)
		#expect(a.superseded.isEmpty)
		#expect(server.records[Self.board]?.values == ["content": "from A"])
	}

	/// Typing during a push that lost: the newer typing grew from the lost value, so only one copy is made
	@Test(arguments: [false, true])
	func typingDuringALosingPushMakesOneCopy(remoteIsNewest: Bool) throws {
		var (server, a, b) = Self.twoDevices()
		server.now += 1000
		b.edit(.board, Self.boardID, ["content": "b1"], server)
		let request = b.replica.makeRequest()
		server.now += 1000
		if remoteIsNewest {
			b.edit(.board, Self.boardID, ["content": "b2"], server)
			server.now += 1000
			a.edit(.board, Self.boardID, ["content": "a1"], server)
			a.syncUntilDone(with: &server)
		} else {
			a.edit(.board, Self.boardID, ["content": "a1"], server)
			a.syncUntilDone(with: &server)
			server.now += 1000
			b.edit(.board, Self.boardID, ["content": "b2"], server)
		}
		let response = try server.sync(request)
		#expect(response.superseded.map(\.lost.value) == ["b1"])
		b.superseded += b.replica.apply(response, sent: request, at: b.now(server)).superseded
		for _ in 0 ..< 2 {
			b.syncUntilDone(with: &server)
			a.syncUntilDone(with: &server)
		}

		#expect(a.superseded.isEmpty)
		#expect(b.superseded.map(\.lost.value) == [remoteIsNewest ? "b2" : "a1"])
		#expect(server.records[Self.board]?.values == ["content": remoteIsNewest ? "a1" : "b2"])
		#expect(b.replica.records == server.records)
	}

	// MARK: - Deleting

	@Test func typingOnAnotherDeviceBringsADeletedBoardBack() {
		var (server, a, b) = Self.twoDevices()
		server.now += 1000
		a.edit(.board, Self.boardID, ["deleted": true], server)
		server.now += 1000
		b.edit(.board, Self.boardID, ["content": "still typing"], server)
		for _ in 0 ..< 2 {
			a.syncUntilDone(with: &server)
			b.syncUntilDone(with: &server)
		}

		#expect(a.replica[.board, Self.boardID]?.isDeleted == false)
		#expect(b.replica.records == a.replica.records)
	}

	@Test func deletingThenUndoingIsAlive() {
		var (server, a, b) = Self.twoDevices()
		server.now += 1000
		a.edit(.board, Self.boardID, ["deleted": true], server)
		a.syncUntilDone(with: &server)
		b.syncUntilDone(with: &server)
		#expect(b.replica[.board, Self.boardID]?.isDeleted == true)

		server.now += 1000
		a.edit(.board, Self.boardID, ["deleted": false], server)
		a.syncUntilDone(with: &server)
		b.syncUntilDone(with: &server)
		#expect(b.replica[.board, Self.boardID]?.isDeleted == false)
		#expect(b.replica[.board, Self.boardID]?.values == ["content": "base", "deleted": false])
	}

	@Test func oldTombstonesLeaveTheDevice() {
		var (server, a, _) = Self.twoDevices()
		server.now += 1000
		a.edit(.board, Self.boardID, ["deleted": true], server)
		a.syncUntilDone(with: &server)
		#expect(a.replica[.board, Self.boardID]?.isDeleted == true)

		server.now += Int64(SyncLimit.tombstoneDays - 1) * 86_400_000
		a.syncUntilDone(with: &server)
		#expect(a.replica[.board, Self.boardID] != nil)

		server.now += 2 * 86_400_000
		a.syncUntilDone(with: &server)
		#expect(a.replica[.board, Self.boardID] == nil)
	}

	// MARK: - Catching up

	/// A new install's defaults are newer than the user's real settings, but mustn't replace them
	@Test func aNewDevicesDefaultsDontReplaceTheAccounts() throws {
		var server = FakeSyncServer()
		var a = FakeDevice("A")
		a.syncUntilDone(with: &server)
		a.edit(.setting, SyncedSetting.logicLetters.rawValue, ["value": ["P", "Q"]], server)
		a.syncUntilDone(with: &server)

		server.now += 60000
		var b = FakeDevice("B")
		b.edit(.setting, SyncedSetting.logicLetters.rawValue, ["value": ["X", "Y"]], server)
		b.edit(.board, Self.boardID, ["content": "made on B", "descriptor.0": "rain"], server)
		let synced = b.sync(with: &server)
		let applied = try #require(synced)
		b.syncUntilDone(with: &server)
		a.syncUntilDone(with: &server)

		#expect(applied.changed.map(\.key) == [Self.letters])
		#expect(b.replica[.setting, SyncedSetting.logicLetters.rawValue]?.values == ["value": ["P", "Q"]])
		#expect(server.records[Self.board]?.values == ["content": "made on B", "descriptor.0": "rain"])
		#expect(a.replica.records == b.replica.records)
		#expect(b.superseded.isEmpty)
	}

	/// After pruning, the device that never saw the tombstone brings the board back, and the device that did
	/// deletes it again, so they still agree
	@Test func resettingAfterPruningAgrees() {
		var (server, a, b) = Self.twoDevices()
		a.edit(.board, Self.otherBoardID, ["content": "other"], server)
		a.syncUntilDone(with: &server)
		b.syncUntilDone(with: &server)

		server.now += 1000
		a.edit(.board, Self.boardID, ["deleted": true], server)
		a.syncUntilDone(with: &server)
		server.prune()
		#expect(server.records[Self.board] == nil)

		let refused = b.sync(with: &server)
		#expect(refused == nil)
		#expect(!b.replica.isCaughtUp)
		for _ in 0 ..< 2 {
			b.syncUntilDone(with: &server)
			a.syncUntilDone(with: &server)
		}

		#expect(b.replica.isCaughtUp)
		#expect(a.replica.records == server.records)
		#expect(b.replica.records == server.records)
		#expect(server.records[Self.board]?.isDeleted == true)
		#expect(server.records[SyncRecord.Key(kind: .board, id: Self.otherBoardID)]?.values == ["content": "other"])
	}

	/// Signing out keeps the data, and signing in to an account that has none of it pushes it all
	@Test func signingInToAnotherAccountPushesEverything() {
		var (server, a, _) = Self.twoDevices()
		a.edit(.setting, SyncedSetting.ditherEnabled.rawValue, ["value": true], server)
		a.syncUntilDone(with: &server)

		var other = FakeSyncServer()
		other.now = server.now
		a.replica.reset()
		a.syncUntilDone(with: &other)
		#expect(other.records == a.replica.records)
		#expect(other.records == server.records)
	}

	// MARK: - Clocks

	/// A clock a day fast before the first sync, then changed again later: nothing is refused for long,
	/// and the stamps end up at server time
	@Test func aFastClockIsCorrected() {
		let day: Int64 = 86_400_000
		var server = FakeSyncServer()
		var device = FakeDevice("A", skew: day)
		device.edit(.board, Self.boardID, ["content": "early"], server)
		device.syncUntilDone(with: &server)

		let early = server.records[Self.board]?.fields["content"]
		#expect(early?.value == "early")
		#expect(early.map { $0.stamp.time <= server.now + SyncLimit.futureStamp } == true)

		server.now += 1000
		device.skew = 2 * day
		device.edit(.board, Self.boardID, ["content": "later"], server)
		let refused = device.sync(with: &server)
		#expect(refused == nil)
		device.syncUntilDone(with: &server)

		let later = server.records[Self.board]?.fields["content"]
		#expect(later?.value == "later")
		#expect(later.map { $0.stamp.time <= server.now + SyncLimit.futureStamp } == true)
		#expect(device.replica.records == server.records)
		#expect(device.replica.pending.isEmpty)

		// Edits made after the correction still beat everything before it
		server.now += 1000
		device.edit(.board, Self.boardID, ["content": "latest"], server)
		device.syncUntilDone(with: &server)
		#expect(server.records[Self.board]?.values == ["content": "latest"])
	}

	// MARK: - Coding

	@Test func replicasRoundTrip() throws {
		var server = FakeSyncServer()
		var device = FakeDevice("A")
		device.edit(.setting, SyncedSetting.logicLetters.rawValue, ["value": ["P"]], server)
		device.syncUntilDone(with: &server)
		device.edit(.board, Self.boardID, ["content": ["english": "It rains."], "descriptor.0": "rain"], server)
		device.replica.reset()
		var fresh = FakeDevice("B")
		fresh.edit(.bookmark, "fallacy.ad-hominem", ["present": true], server)

		for replica in [device.replica, fresh.replica] {
			#expect(try JSONDecoder().decode(SyncReplica.self, from: JSONEncoder().encode(replica)) == replica)
		}
	}
}
