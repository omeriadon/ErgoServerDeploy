//
//  BoardSharingTests.swift
//  ErgoServer
//
//  Created by Adon Omeri on 7/11/2026.
//

import ErgoClient
import ErgoProtocol
@testable import ErgoServer
import Fluent
import Foundation
import Testing
import VaporTesting
#if canImport(FoundationNetworking)
	import FoundationNetworking
#endif

// MARK: - Helpers

extension ServerConfig {
	/// Several accounts per test, and as many syncs as they like
	static func sharing(_ scratch: Scratch) -> ServerConfig {
		var config = ServerConfig.testing(scratch)
		config.accountsPerHour = 100
		config.syncsPerMinute = 100_000
		return config
	}
}

/// A board with one statement, shared by `owner` with `member`
struct SharedFixture {
	let owner: SignedIn
	let member: SignedIn
	let board: String
	let statement: String
	let token: String
}

extension Application {
	func call(_ method: HTTPMethod, _ path: String, token: String?, _ payload: ByteBuffer? = nil) async throws -> TestingHTTPResponse {
		var kept: TestingHTTPResponse?
		let headers: HTTPHeaders = token.map { .signedIn($0) } ?? .version
		try await testing().test(method, path, headers: headers, body: payload) { response async throws in
			kept = response
		}
		return try #require(kept)
	}

	/// Everything the account has, by key
	func pull(_ token: String) async throws -> [SyncRecord.Key: SyncRecord] {
		let response = try await sync(SyncRequest(cursor: nil, changes: []), token: token)
		return Dictionary(uniqueKeysWithValues: response.changes.map { ($0.key, $0) })
	}

	func share(of board: String, token: String) async throws -> BoardShare? {
		try await pull(token)[SyncRecord.Key(kind: .share, id: board)].flatMap { BoardShare($0) }
	}

	func invite(_ board: String, role: BoardRole = .editor, title: String = "Secret canary title", name: String = "Ada", token: String) async throws -> String {
		let response = try await call(.POST, ErgoProtocol.Path.boardInvites(board), token: token, body(CreateBoardInvite(role: role, title: title, name: name)))
		#expect(response.status == .ok)
		let invite = try response.decoded(BoardInvite.self)
		#expect(invite.role == role)
		return try #require(BoardInviteLink.token(from: invite.url))
	}

	@discardableResult
	func accept(_ invite: String, name: String = "Sam", token: String) async throws -> JoinedBoard {
		let response = try await call(.POST, ErgoProtocol.Path.inviteAccept, token: token, body(AcceptBoardInvite(token: invite, name: name)))
		#expect(response.status == .ok)
		return try response.decoded(JoinedBoard.self)
	}

	/// A board and a statement on it, synced by a new account
	func syncedBoard(owner: SignedIn) async throws -> (board: String, statement: String) {
		let board = newBoardID()
		let statement = newBoardID()
		_ = try await sync(SyncRequest(cursor: nil, changes: [
			boardChange(board, ["created": SyncField(value: 1, stamp: stamp(-20000))]),
			statementChange(statement, [
				"board": SyncField(value: .string(board), stamp: stamp(-20000)),
				"content": SyncField(value: content("First"), stamp: stamp(-20000)),
			]),
		]), token: owner.token)
		return (board, statement)
	}

	func sharedFixture(role: BoardRole = .editor) async throws -> SharedFixture {
		let owner = try await signedInAccount("owner")
		let member = try await signedInAccount("member")
		let (board, statement) = try await syncedBoard(owner: owner)
		let token = try await invite(board, role: role, token: owner.token)
		try await accept(token, token: member.token)
		return SharedFixture(owner: owner, member: member, board: board, statement: statement, token: token)
	}
}

// MARK: - Tests

struct BoardSharingTests {
	// MARK: - Joining

	@Test func acceptingCopiesTheRecords() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.sharing(scratch)) { app in
			let owner = try await app.signedInAccount("owner")
			let member = try await app.signedInAccount("member")
			let (board, statement) = try await app.syncedBoard(owner: owner)
			let deleted = newBoardID()
			_ = try await app.sync(SyncRequest(cursor: nil, changes: [
				statementChange(deleted, [
					"board": SyncField(value: .string(board), stamp: stamp(-20000)),
					"deleted": SyncField(value: true, stamp: stamp(-10000)),
				]),
			]), token: owner.token)

			let token = try await app.invite(board, token: owner.token)
			let preview = try await app.call(.POST, ErgoProtocol.Path.invitePreview, token: nil, body(BoardInviteToken(token: token)))
			#expect(try preview.decoded(BoardInvitePreview.self) == BoardInvitePreview(
				board: board, title: "Secret canary title", ownerName: "Ada", role: .editor, memberCount: 1
			))

			let joined = try await app.accept(token, token: member.token)
			#expect(joined == JoinedBoard(board: board, role: .editor))

			let records = try await app.pull(member.token)
			#expect(records[SyncRecord.Key(kind: .board, id: board)]?.fields["created"]?.value == 1)
			#expect(records[SyncRecord.Key(kind: .statement, id: statement)]?.fields["content"]?.value == content("First"))
			#expect(records[SyncRecord.Key(kind: .statement, id: deleted)] == nil)

			let share = try #require(try await app.share(of: board, token: member.token))
			#expect(share.role == .editor)
			#expect(share.members.map(\.name) == ["Ada", "Sam"])
			#expect(share.members.map(\.role) == [.owner, .editor])
			#expect(share.members.last?.id == share.member)

			let ownersShare = try #require(try await app.share(of: board, token: owner.token))
			#expect(ownersShare.role == .owner)
			#expect(ownersShare.members == share.members)

			// Accepting again, or as the owner, keeps the role
			#expect(try await app.accept(token, name: "Someone Else", token: member.token).role == .editor)
			#expect(try await app.accept(token, token: owner.token).role == .owner)
			#expect(try await app.share(of: board, token: member.token)?.members.count == 2)
		}
	}

	@Test func theRawTokenIsNeverStored() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.sharing(scratch)) { app in
			let fixture = try await app.sharedFixture()
			let row = try #require(try await BoardInviteRow.query(on: app.db).first())
			#expect(row.tokenHash == Account.hash(fixture.token))
			#expect(row.tokenHash != fixture.token)
		}
	}

	@Test func refusesBadNamesAndRoles() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.sharing(scratch)) { app in
			let owner = try await app.signedInAccount("owner")
			let (board, _) = try await app.syncedBoard(owner: owner)
			let path = ErgoProtocol.Path.boardInvites(board)

			for bad in [
				CreateBoardInvite(role: .owner, title: "T", name: "Ada"),
				CreateBoardInvite(role: .editor, title: String(repeating: "a", count: 201), name: "Ada"),
				CreateBoardInvite(role: .editor, title: "T", name: "   "),
				CreateBoardInvite(role: .editor, title: "T", name: String(repeating: "a", count: 61)),
			] {
				let response = try await app.call(.POST, path, token: owner.token, body(bad))
				#expect(response.status == .badRequest)
			}
		}
	}

	@Test func aBoardMustBeSyncedFirst() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.sharing(scratch)) { app in
			let owner = try await app.signedInAccount("owner")
			let path = ErgoProtocol.Path.boardInvites(newBoardID())
			let response = try await app.call(.POST, path, token: owner.token, body(CreateBoardInvite(role: .editor, title: "T", name: "Ada")))
			#expect(response.status == .badRequest)
			#expect(try response.decoded(ServiceError.self).message == "Expected a synced board, sync and try again")
		}
	}

	@Test func closedInvitesAreRefused() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.sharing(scratch)) { app in
			let owner = try await app.signedInAccount("owner")
			let member = try await app.signedInAccount("member")
			let (board, _) = try await app.syncedBoard(owner: owner)
			let token = try await app.invite(board, token: owner.token)

			// Expired
			let row = try #require(try await BoardInviteRow.query(on: app.db).first())
			row.expires = .now - 60
			try await row.save(on: app.db)

			let expired = try await app.call(.POST, ErgoProtocol.Path.inviteAccept, token: member.token, body(AcceptBoardInvite(token: token, name: "Sam")))
			#expect(expired.status == .badRequest)
			#expect(try expired.decoded(ServiceError.self) == .inviteClosed)
			let previewed = try await app.call(.POST, ErgoProtocol.Path.invitePreview, token: nil, body(BoardInviteToken(token: token)))
			#expect(try previewed.decoded(ServiceError.self) == .inviteClosed)

			// Revoked
			let open = try await app.invite(board, token: owner.token)
			#expect(try await app.call(.DELETE, ErgoProtocol.Path.boardInvites(board), token: owner.token).status == .noContent)
			let revoked = try await app.call(.POST, ErgoProtocol.Path.inviteAccept, token: member.token, body(AcceptBoardInvite(token: open, name: "Sam")))
			#expect(try revoked.decoded(ServiceError.self) == .inviteClosed)
			#expect(try await BoardMemberRow.query(on: app.db).count() == 1)
		}
	}

	@Test func keepsAtMostTwentyOpenInvites() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.sharing(scratch)) { app in
			let owner = try await app.signedInAccount("owner")
			let (board, _) = try await app.syncedBoard(owner: owner)
			for _ in 0 ..< 22 {
				_ = try await app.invite(board, token: owner.token)
			}
			#expect(try await BoardInviteRow.query(on: app.db).count() == BoardSharing.invitesPerBoard)
		}
	}

	// MARK: - Pushing

	@Test func anEditReachesOtherMembersWithTheirOwnCursor() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.sharing(scratch)) { app in
			let fixture = try await app.sharedFixture()
			let ownerCursor = try await app.sync(SyncRequest(cursor: nil, changes: []), token: fixture.owner.token).cursor
			let memberCursor = try await app.sync(SyncRequest(cursor: nil, changes: []), token: fixture.member.token).cursor

			let edit = SyncField(value: content("Edited"), stamp: stamp())
			let pushed = try await app.sync(
				SyncRequest(cursor: memberCursor, changes: [statementChange(fixture.statement, ["content": edit])]),
				token: fixture.member.token
			)
			#expect(pushed.rejected == nil)
			#expect(pushed.cursor == memberCursor + 1)

			let pulled = try await app.sync(SyncRequest(cursor: ownerCursor, changes: []), token: fixture.owner.token)
			#expect(pulled.cursor == ownerCursor + 1)
			#expect(pulled.changes.map(\.id) == [fixture.statement])
			#expect(pulled.changes.first?.fields["content"] == edit)
		}
	}

	@Test func aNewStatementFansOutWithItsBoard() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.sharing(scratch)) { app in
			let fixture = try await app.sharedFixture()
			let added = newBoardID()
			_ = try await app.sync(SyncRequest(cursor: nil, changes: [
				statementChange(added, [
					"board": SyncField(value: .string(fixture.board), stamp: stamp()),
					"content": SyncField(value: content("Added"), stamp: stamp()),
				]),
			]), token: fixture.owner.token)

			let row = try #require(try await SyncRecordRow.find(SyncRecord.Key(kind: .statement, id: added), for: fixture.member.accountID, on: app.db))
			#expect(row.board == fixture.board)
		}
	}

	@Test func aBoardRecordFansOutOnlyCreated() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.sharing(scratch)) { app in
			let fixture = try await app.sharedFixture()
			_ = try await app.sync(SyncRequest(cursor: nil, changes: [
				boardChange(fixture.board, [
					"created": SyncField(value: 2, stamp: stamp()),
					"deleted": SyncField(value: false, stamp: stamp()),
				]),
			]), token: fixture.member.token)

			let owners = try await app.pull(fixture.owner.token)[SyncRecord.Key(kind: .board, id: fixture.board)]
			#expect(owners?.fields["created"]?.value == 2)
			#expect(owners?.fields["deleted"] == nil)
		}
	}

	@Test func aViewersPushIsRejectedAndTheRestGoesThrough() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.sharing(scratch)) { app in
			let fixture = try await app.sharedFixture(role: .viewer)
			let before = try await app.pull(fixture.member.token)
			let current = try #require(before[SyncRecord.Key(kind: .statement, id: fixture.statement)])

			let response = try await app.sync(SyncRequest(cursor: nil, changes: [
				statementChange(fixture.statement, ["content": SyncField(value: content("Not allowed"), stamp: stamp())]),
				SyncChange(kind: .bookmark, id: "fallacy.strawman", fields: ["present": SyncField(value: true, stamp: stamp())]),
			]), token: fixture.member.token)

			#expect(response.rejected == [RejectedChange(kind: .statement, id: fixture.statement, current: current)])
			#expect(response.changes.contains { $0.kind == .bookmark })

			let owners = try await app.pull(fixture.owner.token)
			#expect(owners[SyncRecord.Key(kind: .statement, id: fixture.statement)]?.fields["content"]?.value == content("First"))
			#expect(owners[SyncRecord.Key(kind: .bookmark, id: "fallacy.strawman")] == nil)
		}
	}

	@Test func aRemovedMembersPushIsRejected() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.sharing(scratch)) { app in
			let fixture = try await app.sharedFixture()
			let share = try #require(try await app.share(of: fixture.board, token: fixture.member.token))
			let path = ErgoProtocol.Path.boardMember(fixture.board, share.member.uuidString)
			#expect(try await app.call(.DELETE, path, token: fixture.owner.token).status == .noContent)

			let records = try await app.pull(fixture.member.token)
			#expect(records[SyncRecord.Key(kind: .board, id: fixture.board)]?.isDeleted == true)
			#expect(records[SyncRecord.Key(kind: .share, id: fixture.board)]?.isDeleted == true)
			// Their rows stay, for pruning to delete
			#expect(records[SyncRecord.Key(kind: .statement, id: fixture.statement)] != nil)

			let added = newBoardID()
			let response = try await app.sync(SyncRequest(cursor: nil, changes: [
				statementChange(fixture.statement, ["content": SyncField(value: content("Too late"), stamp: stamp())]),
				statementChange(added, ["board": SyncField(value: .string(fixture.board), stamp: stamp())]),
			]), token: fixture.member.token)
			#expect(response.rejected?.map(\.id) == [fixture.statement, added])
			#expect(response.rejected?.last?.current == nil)

			#expect(try await app.pull(fixture.owner.token)[SyncRecord.Key(kind: .statement, id: fixture.statement)]?.fields["content"]?.value == content("First"))
			#expect(try await app.share(of: fixture.board, token: fixture.owner.token)?.members.count == 1)
		}
	}

	@Test func aPushedShareIsRejected() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.sharing(scratch)) { app in
			let fixture = try await app.sharedFixture(role: .viewer)
			let current = try #require(try await app.pull(fixture.member.token)[SyncRecord.Key(kind: .share, id: fixture.board)])
			let forged = SyncField(value: .string(BoardRole.owner.rawValue), stamp: stamp(60000))

			let response = try await app.sync(SyncRequest(cursor: nil, changes: [
				SyncChange(kind: .share, id: fixture.board, fields: ["role": forged]),
				SyncChange(kind: .share, id: newBoardID(), fields: ["role": forged]),
				SyncChange(kind: .bookmark, id: "razor.occam", fields: ["present": SyncField(value: true, stamp: stamp())]),
			]), token: fixture.member.token)

			#expect(response.rejected?.first == RejectedChange(kind: .share, id: fixture.board, current: current))
			#expect(response.rejected?.last?.current == nil)
			#expect(response.changes.contains { $0.kind == .bookmark })
			#expect(try await app.share(of: fixture.board, token: fixture.member.token)?.role == .viewer)
		}
	}

	@Test func fanOutSkipsARowOnAnotherBoard() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.sharing(scratch)) { app in
			let fixture = try await app.sharedFixture()
			// The owner's private statement, on a board that isn't shared
			let (_, privateStatement) = try await app.syncedBoard(owner: fixture.owner)

			// The editor reuses its id on the shared board
			_ = try await app.sync(SyncRequest(cursor: nil, changes: [
				statementChange(privateStatement, [
					"board": SyncField(value: .string(fixture.board), stamp: stamp()),
					"content": SyncField(value: content("Reached in"), stamp: stamp()),
				]),
			]), token: fixture.member.token)

			let owners = try await app.pull(fixture.owner.token)
			#expect(owners[SyncRecord.Key(kind: .statement, id: privateStatement)]?.fields["content"]?.value == content("First"))
		}
	}

	@Test func movingARecordOffASharedBoardIsRejected() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.sharing(scratch)) { app in
			let fixture = try await app.sharedFixture()
			for moved in [JSONValue.string(newBoardID()), .number(1)] {
				let response = try await app.sync(SyncRequest(cursor: nil, changes: [
					statementChange(fixture.statement, ["board": SyncField(value: moved, stamp: stamp())]),
				]), token: fixture.member.token)
				#expect(response.rejected?.map(\.id) == [fixture.statement])
			}
		}
	}

	@Test func fanOutDoesntCountAgainstAnotherMembersLimit() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.sharing(scratch)
		// The board, its statement and the share, and one more for the owner's new statement
		config.recordsPerAccount = 4

		try await withTestApp(config) { app in
			let fixture = try await app.sharedFixture()
			_ = try await app.sync(SyncRequest(cursor: nil, changes: [
				SyncChange(kind: .bookmark, id: "razor.occam", fields: ["present": SyncField(value: true, stamp: stamp())]),
			]), token: fixture.member.token)

			let added = newBoardID()
			_ = try await app.sync(SyncRequest(cursor: nil, changes: [
				statementChange(added, ["board": SyncField(value: .string(fixture.board), stamp: stamp())]),
			]), token: fixture.owner.token)

			#expect(try await SyncRecordRow.query(on: app.db).filter(\.$account.$id == fixture.member.accountID).count() == 5)
		}
	}

	// MARK: - Only the owner

	@Test func onlyTheOwnerManagesTheBoard() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.sharing(scratch)) { app in
			let fixture = try await app.sharedFixture()
			let share = try #require(try await app.share(of: fixture.board, token: fixture.member.token))
			let ownerID = try #require(share.members.first?.id)
			let member = ErgoProtocol.Path.boardMember(fixture.board, share.member.uuidString)
			let token = fixture.member.token

			let refused = try await [
				app.call(.POST, ErgoProtocol.Path.boardInvites(fixture.board), token: token, body(CreateBoardInvite(role: .editor, title: "T", name: "Sam"))),
				app.call(.DELETE, ErgoProtocol.Path.boardInvites(fixture.board), token: token),
				app.call(.POST, member, token: token, body(UpdateBoardMember(role: .viewer))),
				app.call(.DELETE, member, token: token),
				app.call(.DELETE, ErgoProtocol.Path.boardShare(fixture.board), token: token),
			]
			for response in refused {
				#expect(response.status == .badRequest)
				#expect(try response.decoded(ServiceError.self) == .notBoardOwner)
			}
			#expect(try await BoardMemberRow.query(on: app.db).count() == 2)

			// Nor can the owner change or remove themselves
			let owner = ErgoProtocol.Path.boardMember(fixture.board, ownerID.uuidString)
			#expect(try await app.call(.DELETE, owner, token: fixture.owner.token).status == .badRequest)
			#expect(try await app.call(.POST, owner, token: fixture.owner.token, body(UpdateBoardMember(role: .viewer))).status == .badRequest)
		}
	}

	@Test func changingARoleTakesEffectOnTheNextPush() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.sharing(scratch)) { app in
			let fixture = try await app.sharedFixture()
			let share = try #require(try await app.share(of: fixture.board, token: fixture.member.token))
			let path = ErgoProtocol.Path.boardMember(fixture.board, share.member.uuidString)
			#expect(try await app.call(.POST, path, token: fixture.owner.token, body(UpdateBoardMember(role: .viewer))).status == .noContent)
			#expect(try await app.share(of: fixture.board, token: fixture.member.token)?.role == .viewer)
			#expect(try await app.share(of: fixture.board, token: fixture.owner.token)?.members.last?.role == .viewer)

			let response = try await app.sync(SyncRequest(cursor: nil, changes: [
				statementChange(fixture.statement, ["content": SyncField(value: content("Now refused"), stamp: stamp())]),
			]), token: fixture.member.token)
			#expect(response.rejected?.map(\.id) == [fixture.statement])
		}
	}

	// MARK: - Leaving

	@Test func aMembersTombstoneLeaves() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.sharing(scratch)) { app in
			let fixture = try await app.sharedFixture(role: .viewer)
			let response = try await app.sync(SyncRequest(cursor: nil, changes: [
				boardChange(fixture.board, ["deleted": SyncField(value: true, stamp: stamp())]),
			]), token: fixture.member.token)
			#expect(response.rejected == nil)

			let records = try await app.pull(fixture.member.token)
			#expect(records[SyncRecord.Key(kind: .share, id: fixture.board)]?.isDeleted == true)

			// The board stays for everyone else, without them
			let owners = try await app.pull(fixture.owner.token)
			#expect(owners[SyncRecord.Key(kind: .board, id: fixture.board)]?.isDeleted == false)
			#expect(owners[SyncRecord.Key(kind: .share, id: fixture.board)].flatMap { BoardShare($0) }?.members.count == 1)
			#expect(try await BoardMemberRow.query(on: app.db).count() == 1)
		}
	}

	@Test func theOwnersTombstoneDeletesForEveryone() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.sharing(scratch)) { app in
			let fixture = try await app.sharedFixture()
			_ = try await app.sync(SyncRequest(cursor: nil, changes: [
				boardChange(fixture.board, ["deleted": SyncField(value: true, stamp: stamp())]),
			]), token: fixture.owner.token)

			for token in [fixture.owner.token, fixture.member.token] {
				let records = try await app.pull(token)
				#expect(records[SyncRecord.Key(kind: .board, id: fixture.board)]?.isDeleted == true)
				#expect(records[SyncRecord.Key(kind: .share, id: fixture.board)]?.isDeleted == true)
			}
			#expect(try await BoardShareRow.query(on: app.db).count() == 0)
			#expect(try await BoardMemberRow.query(on: app.db).count() == 0)
			#expect(try await BoardInviteRow.query(on: app.db).count() == 0)
		}
	}

	@Test func stoppingLeavesTheOwnersCopy() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.sharing(scratch)) { app in
			let fixture = try await app.sharedFixture()
			#expect(try await app.call(.DELETE, ErgoProtocol.Path.boardShare(fixture.board), token: fixture.owner.token).status == .noContent)

			let owners = try await app.pull(fixture.owner.token)
			#expect(owners[SyncRecord.Key(kind: .board, id: fixture.board)]?.isDeleted == false)
			#expect(owners[SyncRecord.Key(kind: .share, id: fixture.board)]?.isDeleted == true)

			let members = try await app.pull(fixture.member.token)
			#expect(members[SyncRecord.Key(kind: .board, id: fixture.board)]?.isDeleted == true)
			#expect(members[SyncRecord.Key(kind: .share, id: fixture.board)]?.isDeleted == true)
			#expect(try await BoardShareRow.query(on: app.db).count() == 0)
		}
	}

	@Test func comingBackWithoutAnInviteIsRejected() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.sharing(scratch)) { app in
			let fixture = try await app.sharedFixture()
			_ = try await app.sync(SyncRequest(cursor: nil, changes: [
				boardChange(fixture.board, ["deleted": SyncField(value: true, stamp: stamp())]),
			]), token: fixture.member.token)

			let response = try await app.sync(SyncRequest(cursor: nil, changes: [
				boardChange(fixture.board, ["deleted": SyncField(value: false, stamp: stamp(1000))]),
			]), token: fixture.member.token)
			#expect(response.rejected?.map(\.id) == [fixture.board])
		}
	}

	@Test func rejoiningBringsTheBoardBack() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.sharing(scratch)) { app in
			let fixture = try await app.sharedFixture()
			_ = try await app.sync(SyncRequest(cursor: nil, changes: [
				boardChange(fixture.board, ["deleted": SyncField(value: true, stamp: stamp())]),
			]), token: fixture.member.token)

			// What happens while they're gone reaches them when they come back
			let gone = newBoardID()
			_ = try await app.sync(SyncRequest(cursor: nil, changes: [
				statementChange(fixture.statement, ["deleted": SyncField(value: true, stamp: stamp(100))]),
				statementChange(gone, ["board": SyncField(value: .string(fixture.board), stamp: stamp(100))]),
			]), token: fixture.owner.token)

			try await app.accept(fixture.token, token: fixture.member.token)

			let records = try await app.pull(fixture.member.token)
			#expect(records[SyncRecord.Key(kind: .board, id: fixture.board)]?.isDeleted == false)
			#expect(records[SyncRecord.Key(kind: .share, id: fixture.board)].flatMap { BoardShare($0) }?.members.count == 2)
			#expect(records[SyncRecord.Key(kind: .statement, id: fixture.statement)]?.isDeleted == true)
			#expect(records[SyncRecord.Key(kind: .statement, id: gone)] != nil)

			// For them only
			let owners = try await app.pull(fixture.owner.token)
			#expect(owners[SyncRecord.Key(kind: .board, id: fixture.board)]?.fields["deleted"] == nil)
		}
	}

	// MARK: - Accounts

	@Test func deletingTheOwnersAccountDeletesTheBoardForEveryone() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.sharing(scratch)) { app in
			let fixture = try await app.sharedFixture()
			#expect(try await app.call(.DELETE, ErgoProtocol.Path.account, token: fixture.owner.token).status == .noContent)

			let records = try await app.pull(fixture.member.token)
			#expect(records[SyncRecord.Key(kind: .board, id: fixture.board)]?.isDeleted == true)
			#expect(records[SyncRecord.Key(kind: .share, id: fixture.board)]?.isDeleted == true)
			#expect(try await BoardShareRow.query(on: app.db).count() == 0)
			#expect(try await BoardMemberRow.query(on: app.db).count() == 0)
			#expect(try await SyncRecordRow.query(on: app.db).filter(\.$account.$id == fixture.owner.accountID).count() == 0)
		}
	}

	@Test func deletingAMembersAccountLeavesTheBoard() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.sharing(scratch)) { app in
			let fixture = try await app.sharedFixture()
			#expect(try await app.call(.DELETE, ErgoProtocol.Path.account, token: fixture.member.token).status == .noContent)

			let owners = try await app.pull(fixture.owner.token)
			#expect(owners[SyncRecord.Key(kind: .board, id: fixture.board)]?.isDeleted == false)
			#expect(owners[SyncRecord.Key(kind: .share, id: fixture.board)].flatMap { BoardShare($0) }?.members.count == 1)
			#expect(try await BoardMemberRow.query(on: app.db).count() == 1)
		}
	}

	@Test func appleDeletingAnOwnersAccountDeletesTheBoardForEveryone() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.sharing(scratch)) { app in
			let fixture = try await app.sharedFixture()
			let payload = try await FakeApple.notification("account-delete", subject: "owner")
			#expect(try await app.notify(payload).status == .ok)

			let records = try await app.pull(fixture.member.token)
			#expect(records[SyncRecord.Key(kind: .board, id: fixture.board)]?.isDeleted == true)
			#expect(try await BoardShareRow.query(on: app.db).count() == 0)
		}
	}

	// MARK: - Public routes

	@Test func publicRoutesNeedNoVersionHeader() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.sharing(scratch)) { app in
			try await app.testing().test(.GET, ErgoProtocol.Path.appleAppSiteAssociation) { response async throws in
				#expect(response.status == .ok)
				#expect(response.headers.first(name: .contentType) == "application/json")
				let file = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: [String: [[String: Any]]]]
				let detail = file?["applinks"]?["details"]?.first
				#expect(detail?["appIDs"] as? [String] == ["P6PV2R9443.com.adonis.Ergo"])
				#expect(detail?["components"] as? [[String: String]] == [["/": "/join/*"]])
			}

			try await app.testing().test(.GET, "join/some-token") { response async throws in
				#expect(response.status == .ok)
				let page = String(buffer: response.body)
				#expect(page.contains("ergo://join/some-token"))
				#expect(page.contains("You've been invited to a board on Ergo"))
				#expect(page.contains("noindex"))
				#expect(!page.contains("apple-itunes-app"))
				#expect(response.headers.first(name: "Referrer-Policy") == "no-referrer")
			}

			// Everything else still needs it
			try await app.testing().test(.GET, ErgoProtocol.Path.connections) { response async throws in
				#expect(response.status == .upgradeRequired)
			}
			try await app.testing().test(.POST, "join/some-token") { response async throws in
				#expect(response.status == .upgradeRequired)
			}
		}
	}

	@Test func theJoinPageEscapesItsToken() {
		let page = JoinController.html(token: #""><script>alert(1)</script>"#, appStoreID: "123")
		#expect(!page.contains("<script>"))
		#expect(page.contains(#"content="app-id=123""#))
		#expect(page.contains("https://apps.apple.com/app/id123"))
	}

	@Test func previewsAreLimitedPerAddress() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.sharing(scratch)
		config.invitePreviewsPerMinute = 1

		try await withTestApp(config) { app in
			let first = try await app.call(.POST, ErgoProtocol.Path.invitePreview, token: nil, body(BoardInviteToken(token: "nope")))
			#expect(first.status == .badRequest)
			let second = try await app.call(.POST, ErgoProtocol.Path.invitePreview, token: nil, body(BoardInviteToken(token: "nope")))
			#expect(second.status == .tooManyRequests)
		}
	}

	// MARK: - Logs

	@Test func logsHoldNoTokensTitlesOrNames() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withLiveServer(.sharing(scratch)) { app, server in
			let logs = CapturedLogs()
			app.logger = logs.logger

			let (owner, ownerSignedIn) = try await SyncLiveTests().device(server, "owner")
			let (member, memberSignedIn) = try await SyncLiveTests().device(server, "member")
			app.ergo.verbose.remember(ownerSignedIn.accountID)
			app.ergo.verbose.remember(memberSignedIn.accountID)
			let board = newBoardID()
			_ = try await owner.sync(SyncRequest(cursor: nil, changes: [boardChange(board, ["created": SyncField(value: 1, stamp: stamp())])]))

			let invite = try await owner.createBoardInvite(board: board, CreateBoardInvite(role: .editor, title: "Title canary", name: "Owner canary"))
			let token = try #require(BoardInviteLink.token(from: invite.url))
			_ = try await member.previewBoardInvite(token: token)
			_ = try await member.acceptBoardInvite(token: token, name: "Member canary")
			try await member.registerPushDevice(token: "abcdef0123456789")

			let (_, response) = try await URLSession.shared.data(from: server.appending(path: "join/\(token)"))
			#expect((response as? HTTPURLResponse)?.statusCode == 200)

			let everything = logs.all.joined(separator: "\n")
			// The server did log, so an empty capture can't pass
			#expect(everything.contains("Made a board invite"))
			#expect(everything.contains("Joined a shared board"))
			// Someone without the app opening a link is as normal as it gets, and has no account to be verbose
			#expect(!everything.contains("/join"))
			for secret in [token, "canary", "abcdef0123456789"] {
				#expect(!everything.contains(secret), "Expected the logs without '\(secret.prefix(6))…', found it")
			}
		}
	}
}
