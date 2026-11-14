//
//  LiveServerTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 14/11/2026.
//

import ErgoClient
import ErgoProtocol
@testable import ErgoSync
import Foundation
import Testing
#if canImport(FoundationNetworking)
	import FoundationNetworking
#endif

/// Everything a running server does over its API, as the app would ask for it, except Sign in with Apple and the AI runs.
/// Skipped unless `ERGO_LIVE_SERVER` holds the server's address:
///
///     ERGO_LIVE_SERVER=https://ergo-15.235.184.129.sslip.io swift test --filter ErgoLiveTests
///
/// It makes four accounts and deletes them at the end, even when something fails. A server allows five new accounts an
/// hour from one address, so it can run once an hour. Emails are made up on `example.com`, and nothing secret is printed.
@Suite(.serialized, .enabled(if: LiveServer.url != nil, "Set ERGO_LIVE_SERVER to a server's address"))
struct LiveServerTests {
	@Test func publicPagesAnswer() async throws {
		let server = try #require(LiveServer.url)
		for path in [ErgoProtocol.Path.privacyPolicy, ErgoProtocol.Path.terms, ErgoProtocol.Path.appleAppSiteAssociation] {
			let (data, response) = try await URLSession.shared.data(from: server.appending(path: path))
			#expect((response as? HTTPURLResponse)?.statusCode == 200, "GET /\(path)")
			#expect(!data.isEmpty, "GET /\(path)")
		}
	}

	@Test func everythingButAppleAndAI() async throws {
		let live = try LiveServer()
		do {
			try await live.run()
		} catch {
			await live.cleanUp()
			throw error
		}
		await live.cleanUp()
	}
}

// MARK: - The run

/// The accounts one run makes, kept so they can be deleted whatever happens
final class LiveServer: @unchecked Sendable {
	static var url: URL? {
		ProcessInfo.processInfo.environment["ERGO_LIVE_SERVER"].flatMap { URL(string: $0) }
	}

	let server: URL
	let run = UUID().uuidString.prefix(8).lowercased()

	/// Every token handed out, to delete the accounts behind them at the end
	private var tokens: [String] = []

	init() throws {
		server = try #require(Self.url)
	}

	func client(_ token: String?) -> ErgoClient {
		ErgoClient(server: server, token: token)
	}

	func newAccount() async throws -> ErgoClient {
		let created = try await client(nil).createAccount()
		tokens.append(created.token)
		return client(created.token)
	}

	func email(_ who: String) -> String {
		"ergo-live-\(run)-\(who)@example.com"
	}

	/// Deletes every account still reachable. A token that's already gone is fine.
	func cleanUp() async {
		for token in tokens.reversed() {
			try? await client(token).deleteAccount()
		}
		tokens = []
	}

	func run() async throws {
		let firstPassword = "first-\(UUID().uuidString)"
		let secondPassword = "second-\(UUID().uuidString)"

		// MARK: Anonymous

		let ada = try await newAccount()
		_ = try await ada.usage()
		_ = try await ada.connections()
		await expectCode(.signInRequired, "syncing before signing in") {
			_ = try await ada.sync(SyncRequest(cursor: nil, changes: []))
		}
		await expectCode(.unauthorized, "a made-up token") {
			_ = try await self.client("not-a-real-token").usage()
		}

		// MARK: Registering

		await expectCode(.invalidRequest, "a password that's too short") {
			try await ada.register(email: self.email("ada"), password: "x")
		}
		try await ada.register(email: email("ada"), password: firstPassword)
		await expectCode(.invalidRequest, "registering twice") {
			try await ada.register(email: self.email("ada-again"), password: firstPassword)
		}

		// MARK: Syncing

		let board = UUID().uuidString
		let first = UUID().uuidString
		let second = UUID().uuidString
		let link = UUID().uuidString
		let scratchpad = UUID().uuidString
		let pushed = try await ada.sync(SyncRequest(cursor: nil, changes: [
			change(.board, board, ["created": 1, "name": "Live test board"]),
			change(.statement, first, ["board": .string(board), "content": "It rained."]),
			change(.statement, second, ["board": .string(board), "content": "The ground is wet."]),
			change(.link, link, ["board": .string(board), "premise": .string(first), "conclusion": .string(second)]),
			change(.scratchpad, scratchpad, ["created": 1, "content": ["english": "P", "logic": [], "source": "english"]]),
		]))
		#expect(pushed.rejected == nil)
		let records = try await pull(ada)
		#expect(records[key(.statement, first)]?.fields["content"]?.value == "It rained.")
		#expect(records[key(.link, link)]?.fields["premise"]?.value == .string(first))
		#expect(records[key(.scratchpad, scratchpad)] != nil)

		// An edit comes back, and a deletion leaves a tombstone
		_ = try await ada.sync(SyncRequest(cursor: pushed.cursor, changes: [
			change(.statement, first, ["content": "It rained all night."], at: 1000),
			change(.scratchpad, scratchpad, ["deleted": true], at: 1000),
		]))
		let edited = try await pull(ada)
		#expect(edited[key(.statement, first)]?.fields["content"]?.value == "It rained all night.")
		#expect(edited[key(.scratchpad, scratchpad)]?.fields["deleted"]?.value == true)

		// MARK: A second device, by email

		let phone = try await newAccount()
		await expectCode(.invalidCredentials, "a wrong password") {
			_ = try await phone.logIn(email: self.email("ada"), password: "wrong-\(UUID().uuidString)")
		}
		let signedIn = try await phone.logIn(email: email("ada"), password: firstPassword)
		#expect(!signedIn.isNewAccount)
		let onThePhone = try await pull(phone)
		#expect(onThePhone[key(.statement, first)]?.fields["content"]?.value == "It rained all night.")

		// MARK: Changing the password

		await expectCode(.invalidCredentials, "the wrong current password") {
			try await ada.changePassword(current: "wrong-\(UUID().uuidString)", new: secondPassword)
		}
		try await ada.changePassword(current: firstPassword, new: secondPassword)
		await expectCode(.unauthorized, "the other device after a password change") {
			_ = try await phone.usage()
		}
		_ = try await ada.usage()
		await expectCode(.invalidCredentials, "the old password") {
			_ = try await ada.logIn(email: self.email("ada"), password: firstPassword)
		}
		let again = try await ada.logIn(email: email("ada"), password: secondPassword)
		#expect(again.accountID == signedIn.accountID)

		// MARK: Sharing a board

		let sam = try await newAccount()
		await expectCode(.emailInUse, "someone else's email") {
			try await sam.register(email: self.email("ada"), password: firstPassword)
		}
		try await sam.register(email: email("sam"), password: firstPassword)

		let invite = try await ada.createBoardInvite(board: board, CreateBoardInvite(role: .editor, title: "Live test board", name: "Ada"))
		#expect(invite.role == .editor)
		let token = try #require(BoardInviteLink.token(from: invite.url))

		let preview = try await client(nil).previewBoardInvite(token: token)
		#expect(preview.board == board)
		#expect(preview.ownerName == "Ada")
		#expect(preview.memberCount == 1)

		let joined = try await sam.acceptBoardInvite(token: token, name: "Sam")
		#expect(joined == JoinedBoard(board: board, role: .editor))

		let samsCopy = try await pull(sam)
		#expect(samsCopy[key(.statement, second)]?.fields["content"]?.value == "The ground is wet.")
		let share = try #require(samsCopy[key(.share, board)].flatMap { BoardShare($0) })
		#expect(share.members.map(\.name) == ["Ada", "Sam"])
		let samID = share.member

		// An editor's edit reaches the owner
		let samsEdit = try await sam.sync(SyncRequest(cursor: nil, changes: [
			change(.statement, second, ["content": "The ground is soaked."], at: 2000),
		]))
		#expect(samsEdit.rejected == nil)
		#expect(try await pull(ada)[key(.statement, second)]?.fields["content"]?.value == "The ground is soaked.")

		// A viewer's isn't taken
		try await ada.updateBoardMember(board: board, member: samID, role: .viewer)
		let refused = try await sam.sync(SyncRequest(cursor: nil, changes: [
			change(.statement, second, ["content": "A viewer's edit."], at: 3000),
		]))
		#expect(refused.rejected?.map(\.id) == [second])
		#expect(try await pull(ada)[key(.statement, second)]?.fields["content"]?.value == "The ground is soaked.")

		try await sam.reportBoard(board: board, reason: "Automated live test of reporting, please ignore.")

		// Revoked links stop working
		try await ada.revokeBoardInvites(board: board)
		await expectAnyError("previewing a revoked link") {
			_ = try await self.client(nil).previewBoardInvite(token: token)
		}

		// Removed, and then no longer shared at all
		try await ada.removeBoardMember(board: board, member: samID)
		let afterRemoval = try await pull(sam)
		#expect(afterRemoval[key(.share, board)].flatMap { BoardShare($0) }?.members.contains { $0.id == samID } != true)

		let secondInvite = try await ada.createBoardInvite(board: board, CreateBoardInvite(role: .viewer, title: "Live test board", name: "Ada"))
		_ = try await sam.acceptBoardInvite(token: #require(BoardInviteLink.token(from: secondInvite.url)), name: "Sam")
		try await ada.stopSharingBoard(board: board)
		await expectAnyError("accepting after sharing stopped") {
			_ = try await sam.acceptBoardInvite(token: #require(BoardInviteLink.token(from: secondInvite.url)), name: "Sam")
		}

		// MARK: Pushes

		await expectCode(.invalidRequest, "a push token that isn't hex") {
			try await ada.registerPushDevice(token: "not hex")
		}
		try await ada.registerPushDevice(token: String(repeating: "0a", count: 32))
		try await ada.unregisterPushDevice()

		// MARK: Signing out and deleting

		try await sam.signOut()
		await expectCode(.unauthorized, "a signed-out token") {
			_ = try await sam.usage()
		}

		try await ada.deleteAccount()
		await expectCode(.unauthorized, "a deleted account") {
			_ = try await ada.usage()
		}

		// Sam's account is still there, so a new device signs in to delete it, after checking Ada's email is gone
		let samAgain = try await newAccount()
		await expectCode(.invalidCredentials, "a deleted account's email") {
			_ = try await samAgain.logIn(email: self.email("ada"), password: secondPassword)
		}
		_ = try await samAgain.logIn(email: email("sam"), password: firstPassword)
		try await samAgain.deleteAccount()
		await expectCode(.unauthorized, "a deleted account") {
			_ = try await samAgain.usage()
		}
	}

	// MARK: - Helpers

	/// Stamps a little in the past, `offset` milliseconds apart, so each edit is newer than the last
	func change(_ kind: SyncKind, _ id: String, _ values: [String: JSONValue], at offset: Int64 = 0) -> SyncChange {
		let stamp = SyncStamp(time: Int64(Date.now.timeIntervalSince1970 * 1000) - 60000 + offset, counter: 0, device: "live-\(run)")
		return SyncChange(kind: kind, id: id, fields: values.mapValues { SyncField(value: $0, stamp: stamp) })
	}

	func key(_ kind: SyncKind, _ id: String) -> SyncRecord.Key {
		SyncRecord.Key(kind: kind, id: id)
	}

	/// Everything the account can see, by key
	func pull(_ client: ErgoClient) async throws -> [SyncRecord.Key: SyncRecord] {
		var records: [SyncRecord.Key: SyncRecord] = [:]
		var cursor: Int?
		repeat {
			let response = try await client.sync(SyncRequest(cursor: cursor, changes: []))
			for record in response.changes {
				records[record.key] = record
			}
			cursor = response.cursor
			if !response.more {
				break
			}
		} while true
		return records
	}

	func expectCode(_ code: ServiceError.Code, _ what: String, sourceLocation: SourceLocation = #_sourceLocation, _ work: () async throws -> Void) async {
		do {
			try await work()
			Issue.record("Expected \(code) for \(what), but it worked", sourceLocation: sourceLocation)
		} catch let error as ServiceError {
			#expect(error.code == code, "\(what): \(error.message)", sourceLocation: sourceLocation)
		} catch {
			Issue.record("Expected \(code) for \(what), got \(error)", sourceLocation: sourceLocation)
		}
	}

	func expectAnyError(_ what: String, sourceLocation: SourceLocation = #_sourceLocation, _ work: () async throws -> Void) async {
		do {
			try await work()
			Issue.record("Expected \(what) to fail, but it worked", sourceLocation: sourceLocation)
		} catch {}
	}
}
