//
//  BoardShareTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 7/11/2026.
//

import ErgoSync
import Foundation
import Testing

/// Who's on a shared board, and what a replica does with changes the server refuses
struct BoardShareTests {
	static let boardID = "6F1C2E9A-3B4D-4E5F-8A9B-0C1D2E3F4A5B"
	static let statementID = "AAAAAAAA-2222-4333-8444-555555555555"
	static let otherID = "BBBBBBBB-2222-4333-8444-555555555555"
	static let statement = SyncRecord.Key(kind: .statement, id: statementID)
	static let shareKey = SyncRecord.Key(kind: .share, id: boardID)
	static let stamp = SyncStamp(time: 1_793_836_800_000, counter: 0, device: "server")

	static let owner = BoardMember(id: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!, name: "Ada", role: .owner)
	static let viewer = BoardMember(id: UUID(uuidString: "22222222-2222-4333-8444-555555555555")!, name: "Sam", role: .viewer)
	static let share = BoardShare(board: boardID, role: .viewer, member: viewer.id, members: [owner, viewer])

	static func shareRecord(_ fields: [String: JSONValue] = share.fields, stamp: SyncStamp = stamp) -> SyncRecord {
		SyncRecord(kind: .share, id: boardID, fields: fields.mapValues { SyncField(value: $0, stamp: stamp) })
	}

	/// A device holding a statement the server also has, caught up
	static func oneDevice() -> (FakeSyncServer, FakeDevice) {
		var server = FakeSyncServer()
		var device = FakeDevice("A")
		device.syncUntilDone(with: &server)
		device.edit(.statement, statementID, ["board": .string(boardID), "content": "base"], server)
		device.syncUntilDone(with: &server)
		server.now += 1000
		return (server, device)
	}

	/// One round trip where the server refuses everything pushed, and answers with what it has
	static func rejecting(_ device: inout FakeDevice, _ server: inout FakeSyncServer, current: SyncRecord?) -> SyncApplied {
		let request = device.replica.makeRequest()
		let rejected = request.changes.map { RejectedChange(kind: $0.kind, id: $0.id, current: current) }
		let response = SyncResponse(cursor: server.seq, changes: [], more: false, rejected: rejected, serverTime: Date(milliseconds: server.now))
		return device.replica.apply(response, sent: request, at: device.now(server))
	}

	// MARK: - Records

	@Test func aShareRoundTripsThroughARecord() {
		let record = Self.shareRecord()
		#expect(BoardShare(record) == Self.share)
		#expect(Set(Self.share.fields.keys).isSubset(of: SyncKind.share.fieldNames))
	}

	/// Built by hand, so it has to keep matching what `Codable` reads and what an encoder would write
	@Test func aSharesMembersAreTheirJSON() throws {
		#expect(try Self.share.fields[SyncFieldName.members] == JSONValue(Self.share.members))
		#expect(Self.share.fields[SyncFieldName.member] == .string(Self.viewer.id.uuidString))
		#expect(Self.share.fields[SyncFieldName.role] == "viewer")
	}

	/// Nil would make the board look like one nobody shared, which this person could edit
	@Test func aRoleAddedLaterIsAShareThatCanOnlyBeViewed() {
		var newerRole = Self.share.fields
		newerRole[SyncFieldName.role] = "admin"
		#expect(BoardShare(Self.shareRecord(newerRole))?.role == .viewer)
	}

	@Test func aShareIsNilForWhatItCantRead() {
		var wrongKind = Self.shareRecord()
		wrongKind.kind = .board
		#expect(BoardShare(wrongKind) == nil)

		var tombstone = Self.shareRecord()
		tombstone.fields[SyncFieldName.deleted] = SyncField(value: true, stamp: SyncStamp(time: Self.stamp.time + 1, counter: 0, device: "server"))
		#expect(BoardShare(tombstone) == nil)

		var badMember = Self.share.fields
		badMember[SyncFieldName.member] = "not a uuid"
		#expect(BoardShare(Self.shareRecord(badMember)) == nil)

		var badMembers = Self.share.fields
		badMembers[SyncFieldName.members] = [["id": "not a uuid", "name": "Sam", "role": "viewer"]]
		#expect(BoardShare(Self.shareRecord(badMembers)) == nil)

		var missing = Self.share.fields
		missing[SyncFieldName.members] = nil
		#expect(BoardShare(Self.shareRecord(missing)) == nil)
	}

	@Test func joiningAgainAfterATombstoneIsAlive() {
		var record = Self.shareRecord()
		record.merge([SyncFieldName.deleted: SyncField(value: true, stamp: SyncStamp.server(after: record.newestStamp, now: Self.stamp.date))])
		#expect(BoardShare(record) == nil)

		let stamp = SyncStamp.server(after: record.newestStamp, now: Self.stamp.date)
		record.merge(Self.share.fields.mapValues { SyncField(value: $0, stamp: stamp) })
		#expect(BoardShare(record) == Self.share)
	}

	@Test func rolesKnowWhoCanEdit() {
		#expect(BoardRole.owner.canEdit)
		#expect(BoardRole.editor.canEdit)
		#expect(!BoardRole.viewer.canEdit)
	}

	@Test func theShareKindIsServerOwned() {
		#expect(SyncKind.share.rawValue == "share")
		#expect(SyncKind.share.isServerOwned)
		#expect(SyncKind.known.allSatisfy { !$0.isServerOwned })
		#expect(SyncKind.share.fieldNames == ["role", "member", "members", "deleted"])
		#expect(SyncKind.share.isValid(id: Self.boardID))
		#expect(!SyncKind.share.isValid(id: Self.boardID.lowercased()))
	}

	// MARK: - Stamps

	@Test(arguments: [
		// The server's clock is ahead, level with, and behind what the record has
		SyncStamp(time: 1000, counter: 7, device: "iPhone"),
		SyncStamp(time: 5000, counter: 7, device: "zzz"),
		SyncStamp(time: 9000, counter: 7, device: "zzz"),
	])
	func serverStampsAreAlwaysNewer(newest: SyncStamp) {
		let stamp = SyncStamp.server(after: newest, now: Date(milliseconds: 5000))
		#expect(stamp > newest)
		#expect(stamp.device == "server")
		#expect(stamp.time == max(5000, newest.time))
		#expect(stamp.counter == (newest.time >= 5000 ? newest.counter + 1 : 0))
		#expect(SyncStamp.server(after: stamp, now: Date(milliseconds: 5000)) > stamp)
	}

	@Test func aServerStampForANewRecordIsNow() {
		let stamp = SyncStamp.server(after: nil, now: Date(milliseconds: 5000))
		#expect(stamp == SyncStamp(time: 5000, counter: 0, device: "server"))
	}

	// MARK: - Rejected changes

	@Test func aRejectedChangeBecomesWhatTheServerHas() throws {
		var (server, device) = Self.oneDevice()
		device.edit(.statement, Self.statementID, ["content": "viewer's edit", "position": ["x": 1, "y": 2]], server)
		let current = try #require(server.records[Self.statement])

		let applied = Self.rejecting(&device, &server, current: current)

		#expect(device.replica[.statement, Self.statementID] == current)
		#expect(applied.changed == [current])
		#expect(applied.superseded.isEmpty)
		#expect(!applied.syncAgain)
		#expect(device.replica.pending.isEmpty)
	}

	/// A new statement on a board that can't be edited: the server has nothing, so the app must drop it
	@Test func aRejectedChangeWithNothingOnTheServerIsATombstone() throws {
		var (server, device) = Self.oneDevice()
		device.edit(.statement, Self.otherID, ["board": .string(Self.boardID), "content": "phantom"], server)
		let before = try #require(device.replica[.statement, Self.otherID])

		let applied = Self.rejecting(&device, &server, current: nil)

		let record = try #require(device.replica[.statement, Self.otherID])
		#expect(record.isDeleted)
		#expect(record.values["content"] == "phantom")
		#expect(record.fields["content"] == before.fields["content"])
		#expect(applied.changed == [record])
		#expect(device.replica.pending.isEmpty)
		#expect(device.replica.makeRequest().changes.isEmpty)
		#expect(server.records[SyncRecord.Key(kind: .statement, id: Self.otherID)] == nil)
	}

	@Test func aRejectedChangeNotHeldLocallyDoesNothing() {
		var (server, device) = Self.oneDevice()
		let request = device.replica.makeRequest()
		let response = SyncResponse(
			cursor: server.seq,
			changes: [],
			more: false,
			rejected: [RejectedChange(kind: .statement, id: Self.otherID)],
			serverTime: Date(milliseconds: server.now)
		)
		let applied = device.replica.apply(response, sent: request, at: device.now(server))

		#expect(applied.changed.isEmpty)
		#expect(device.replica[.statement, Self.otherID] == nil)
	}

	@Test func typingDuringARejectedRequestGoesToo() throws {
		var (server, device) = Self.oneDevice()
		device.edit(.statement, Self.statementID, ["content": "first"], server)
		let request = device.replica.makeRequest()
		server.now += 100
		device.edit(.statement, Self.statementID, ["content": "second"], server)
		let current = try #require(server.records[Self.statement])

		let response = SyncResponse(
			cursor: server.seq,
			changes: [],
			more: false,
			rejected: [RejectedChange(kind: .statement, id: Self.statementID, current: current)],
			serverTime: Date(milliseconds: server.now)
		)
		let applied = device.replica.apply(response, sent: request, at: device.now(server))

		#expect(device.replica[.statement, Self.statementID] == current)
		#expect(device.replica.pending.isEmpty)
		#expect(applied.changed == [current])
		#expect(applied.superseded.isEmpty)
		#expect(!applied.syncAgain)
	}

	/// A record the server sends in the same reply it refuses it: what's pulled mustn't push back or make a conflict copy
	@Test func aRejectedChangeAlsoPulledDoesntPushOrCopy() throws {
		var (server, device) = Self.oneDevice()
		var other = FakeDevice("B")
		other.syncUntilDone(with: &server)
		other.edit(.statement, Self.statementID, ["content": "from the owner"], server)
		server.now += 100
		device.edit(.statement, Self.statementID, ["content": "viewer's edit"], server)
		let request = device.replica.makeRequest()
		server.now += 100
		device.edit(.statement, Self.statementID, ["content": "more typing"], server)
		other.syncUntilDone(with: &server)
		let current = try #require(server.records[Self.statement])

		let response = SyncResponse(
			cursor: server.seq,
			changes: [current],
			more: false,
			superseded: [SupersededField(kind: .statement, id: Self.statementID, field: "content", lost: SyncField(value: "viewer's edit", stamp: Self.stamp))],
			rejected: [RejectedChange(kind: .statement, id: Self.statementID, current: current)],
			serverTime: Date(milliseconds: server.now)
		)
		let applied = device.replica.apply(response, sent: request, at: device.now(server))

		#expect(applied.superseded.isEmpty)
		#expect(device.replica.pending.isEmpty)
		#expect(device.replica[.statement, Self.statementID] == current)
		#expect(applied.changed == [current])
	}

	@Test func aRejectedChangeLeavesTheRestOfTheRequest() throws {
		var (server, device) = Self.oneDevice()
		let boardKey = SyncRecord.Key(kind: .board, id: Self.boardID)
		device.edit(.statement, Self.statementID, ["content": "refused"], server)
		device.edit(.board, Self.boardID, ["created": 1], server)
		let request = device.replica.makeRequest()
		let current = try #require(server.records[Self.statement])
		let accepted = try #require(device.replica.records[boardKey])

		let response = SyncResponse(
			cursor: server.seq + 1,
			changes: [accepted],
			more: false,
			rejected: [RejectedChange(kind: .statement, id: Self.statementID, current: current)],
			serverTime: Date(milliseconds: server.now)
		)
		_ = device.replica.apply(response, sent: request, at: device.now(server))

		#expect(device.replica.pending.isEmpty)
		#expect(device.replica.records[boardKey] == accepted)
		#expect(device.replica[.statement, Self.statementID] == current)
	}

	/// The clock has to stay ahead of what the server sent, and a later edit has to beat it
	@Test func editingAfterARejectionBeatsWhatTheServerHas() throws {
		var (server, device) = Self.oneDevice()
		device.edit(.statement, Self.statementID, ["content": "refused"], server)
		var current = try #require(server.records[Self.statement])
		current.fields["content"]?.stamp = SyncStamp(time: server.now + 5000, counter: 9, device: "server")

		_ = Self.rejecting(&device, &server, current: current)
		device.edit(.statement, Self.statementID, ["content": "allowed now"], server)

		let stamp = try #require(device.replica[.statement, Self.statementID]?.fields["content"]?.stamp)
		#expect(try stamp > #require(current.newestStamp))
	}

	@Test func aRejectionClearsSeedsAndUnconfirmed() throws {
		var server = FakeSyncServer()
		var device = FakeDevice("A")
		device.syncUntilDone(with: &server)
		device.edit(.statement, Self.statementID, ["board": .string(Self.boardID), "content": "base"], server)
		device.syncUntilDone(with: &server)
		device.replica.reset()
		#expect(device.replica.unconfirmed?.contains(Self.statement) == true)

		let sent = device.replica.makeRequest()
		let current = try #require(server.records[Self.statement])
		let response = SyncResponse(
			cursor: server.seq,
			changes: [],
			more: true,
			rejected: [RejectedChange(kind: .statement, id: Self.statementID, current: current)],
			serverTime: Date(milliseconds: server.now)
		)
		_ = device.replica.apply(response, sent: sent, at: device.now(server))
		#expect(device.replica.unconfirmed?.contains(Self.statement) == false)

		// Local values waiting for the first pull
		var fresh = FakeDevice("B")
		fresh.edit(.statement, Self.otherID, ["content": "seeded"], server)
		#expect(fresh.replica.seeds?[SyncRecord.Key(kind: .statement, id: Self.otherID)] != nil)
		let freshSent = fresh.replica.makeRequest()
		let freshResponse = SyncResponse(
			cursor: 0,
			changes: [],
			more: true,
			rejected: [RejectedChange(kind: .statement, id: Self.otherID)],
			serverTime: Date(milliseconds: server.now)
		)
		_ = fresh.replica.apply(freshResponse, sent: freshSent, at: fresh.now(server))
		#expect(fresh.replica.seeds?[SyncRecord.Key(kind: .statement, id: Self.otherID)] == nil)
	}

	// MARK: - Server-owned kinds

	/// `share` records come from the server and the replica only reads them
	@Test func serverOwnedRecordsAreNeverPushedAfterAReset() {
		var (server, device) = Self.oneDevice()
		server.write(Self.shareRecord())
		device.syncUntilDone(with: &server)
		#expect(device.replica.records[Self.shareKey] != nil)

		// Removed while the device wasn't looking, and the tombstone was then pruned
		server.rows[Self.shareKey] = nil
		device.replica.reset()
		device.syncUntilDone(with: &server)

		#expect(device.replica.isCaughtUp)
		#expect(device.replica.records[Self.shareKey] == nil)
		#expect(server.records[Self.shareKey] == nil)
		#expect(device.replica.pending.isEmpty)
		#expect(device.replica[.statement, Self.statementID] != nil)
	}

	@Test func aServerOwnedRecordTheFullPullReturnsStays() {
		var (server, device) = Self.oneDevice()
		server.write(Self.shareRecord())
		device.syncUntilDone(with: &server)

		device.replica.reset()
		device.syncUntilDone(with: &server)

		#expect(BoardShare(device.replica.records[Self.shareKey] ?? Self.shareRecord([:])) == Self.share)
		#expect(device.replica.pending.isEmpty)
	}

	/// A field the server's copy lacks would normally be pushed back
	@Test func aServerOwnedRecordIsNotRepushedWhenItsMissingAField() {
		var (server, device) = Self.oneDevice()
		var record = Self.shareRecord()
		record.fields[SyncFieldName.deleted] = SyncField(value: false, stamp: Self.stamp)
		server.write(record)
		device.syncUntilDone(with: &server)

		record.fields[SyncFieldName.deleted] = nil
		record.fields[SyncFieldName.role]?.stamp = SyncStamp(time: Self.stamp.time + 1, counter: 0, device: "server")
		server.write(record)
		device.syncUntilDone(with: &server)

		#expect(device.replica.pending.isEmpty)
		#expect(server.records[Self.shareKey]?.fields[SyncFieldName.deleted] == nil)
	}

	@Test func aServerOwnedSeedIsNeverPushed() {
		var server = FakeSyncServer()
		var device = FakeDevice("A")
		device.edit(.share, Self.boardID, ["role": "owner"], server)
		device.syncUntilDone(with: &server)

		#expect(device.replica.isCaughtUp)
		#expect(device.replica.pending.isEmpty)
		#expect(server.records.isEmpty)
	}

	// MARK: - Forgetting

	@Test func forgettingRemovesEverything() {
		var (server, device) = Self.oneDevice()
		device.edit(.statement, Self.statementID, ["content": "unsent"], server)
		device.replica.reset()
		device.edit(.statement, Self.otherID, ["board": .string(Self.boardID), "content": "other"], server)

		device.replica.forget([Self.statement])

		#expect(device.replica.records[Self.statement] == nil)
		#expect(device.replica.pending[Self.statement] == nil)
		#expect(device.replica.unconfirmed?.contains(Self.statement) == false)
		#expect(device.replica[.statement, Self.otherID] != nil)

		device.syncUntilDone(with: &server)
		#expect(server.records[Self.statement] != nil)
		#expect(device.replica[.statement, Self.statementID] != nil)
		#expect(server.records[Self.statement]?.values["content"] == "base")
	}

	@Test func forgettingASeedKeepsItFromBeingPushed() {
		var server = FakeSyncServer()
		var device = FakeDevice("A")
		device.edit(.statement, Self.statementID, ["board": .string(Self.boardID), "content": "seeded"], server)
		#expect(device.replica.seeds?[Self.statement] != nil)

		device.replica.forget([Self.statement])
		#expect(device.replica.seeds?[Self.statement] == nil)

		device.syncUntilDone(with: &server)
		#expect(server.records.isEmpty)
	}
}

// MARK: - Server writes

extension FakeSyncServer {
	/// A record the server writes itself, as `BoardSharing` does
	mutating func write(_ record: SyncRecord) {
		seq += 1
		rows[record.key] = Row(record: record, seq: seq)
	}
}
