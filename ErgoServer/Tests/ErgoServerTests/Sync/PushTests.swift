//
//  PushTests.swift
//  ErgoServer
//
//  Created by Adon Omeri on 7/11/2026.
//

import Crypto
import ErgoClient
import ErgoProtocol
@testable import ErgoServer
import Fluent
import Foundation
import Logging
import Synchronization
import Testing
import VaporTesting

/// Stands in for Apple, keeping what it was asked to send
final class FakePush: Sendable {
	private let messages = Mutex<[PushMessage]>([])
	private let outcome: PushOutcome

	init(outcome: PushOutcome = .sent) {
		self.outcome = outcome
	}

	var sent: [PushMessage] {
		messages.withLock { $0 }
	}

	var sender: PushSender {
		PushSender(isEnabled: true) { [self] message in
			messages.withLock { $0.append(message) }
			return outcome
		}
	}
}

extension Application {
	func registerPush(_ apnsToken: String, token: String) async throws {
		let response = try await call(.PUT, ErgoProtocol.Path.pushDevice, token: token, body(PushDevice(token: apnsToken)))
		#expect(response.status == .noContent)
	}
}

struct PushTests {
	// MARK: - Throttle

	@Test func editsAlertOnceAQuarterHourThenGoSilent() {
		let throttle = PushThrottle()
		let account = UUID()
		let start = Date.now

		#expect(throttle.decide(board: "A", account: account, now: start) == .alert)
		#expect(throttle.decide(board: "A", account: account, now: start + 1) == .silent)
		#expect(throttle.decide(board: "A", account: account, now: start + 30) == .nothing)
		#expect(throttle.decide(board: "A", account: account, now: start + 61) == .silent)
		// Another board and another person have limits of their own
		#expect(throttle.decide(board: "B", account: account, now: start + 62) == .alert)
		#expect(throttle.decide(board: "A", account: UUID(), now: start + 62) == .alert)
		#expect(throttle.decide(board: "A", account: account, now: start + PushThrottle.alertWindow + 1) == .alert)
	}

	@Test func editsThroughTheRouteAreThrottled() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		let push = FakePush()

		try await withTestApp(.sharing(scratch), push: push.sender) { app in
			let fixture = try await app.sharedFixture()
			try await app.registerPush("aa11", token: fixture.owner.token)

			for edit in 0 ..< 3 {
				_ = try await app.sync(SyncRequest(cursor: nil, changes: [
					statementChange(fixture.statement, ["content": SyncField(value: content("Edit \(edit)"), stamp: stamp(Int64(edit)))]),
				]), token: fixture.member.token)
			}

			#expect(try await eventually { push.sent.count == 2 })
			// Each send is its own task, so either could arrive first
			#expect(push.sent.contains { $0.alert == PushMessage.Alert(title: "Sam edited", body: "Secret canary title") })
			#expect(push.sent.contains { $0.alert == nil })
			#expect(push.sent.allSatisfy { $0.board == fixture.board })
			// The one who edited hears nothing
			#expect(push.sent.allSatisfy { $0.deviceToken == "aa11" })
		}
	}

	// MARK: - Events

	@Test func joiningTellsTheOwner() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		let push = FakePush()

		try await withTestApp(.sharing(scratch), push: push.sender) { app in
			let owner = try await app.signedInAccount("owner")
			let member = try await app.signedInAccount("member")
			try await app.registerPush("aa11", token: owner.token)
			let (board, _) = try await app.syncedBoard(owner: owner)
			let token = try await app.invite(board, token: owner.token)
			try await app.accept(token, token: member.token)

			#expect(try await eventually { push.sent.count == 1 })
			#expect(push.sent == [PushMessage(
				deviceToken: "aa11",
				board: board,
				alert: PushMessage.Alert(title: "Sam joined", body: "Secret canary title")
			)])
		}
	}

	@Test func aMemberHearsWhatHappensToThem() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		let push = FakePush()

		try await withTestApp(.sharing(scratch), push: push.sender) { app in
			let fixture = try await app.sharedFixture()
			try await app.registerPush("bb22", token: fixture.member.token)
			let share = try #require(try await app.share(of: fixture.board, token: fixture.member.token))
			let path = ErgoProtocol.Path.boardMember(fixture.board, share.member.uuidString)

			_ = try await app.call(.POST, path, token: fixture.owner.token, body(UpdateBoardMember(role: .viewer)))
			#expect(try await eventually { push.sent.count == 1 })
			#expect(push.sent.last?.alert?.title == "You can now only view")

			_ = try await app.call(.POST, path, token: fixture.owner.token, body(UpdateBoardMember(role: .editor)))
			#expect(try await eventually { push.sent.count == 2 })
			#expect(push.sent.last?.alert?.title == "You can now edit")

			_ = try await app.call(.DELETE, path, token: fixture.owner.token)
			#expect(try await eventually { push.sent.count == 3 })
			#expect(push.sent.last?.alert?.title == "You were removed")
		}
	}

	@Test func deletingTheBoardTellsTheMembers() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		let push = FakePush()

		try await withTestApp(.sharing(scratch), push: push.sender) { app in
			let fixture = try await app.sharedFixture()
			try await app.registerPush("bb22", token: fixture.member.token)
			_ = try await app.sync(SyncRequest(cursor: nil, changes: [
				boardChange(fixture.board, ["deleted": SyncField(value: true, stamp: stamp())]),
			]), token: fixture.owner.token)

			#expect(try await eventually { push.sent.count == 1 })
			#expect(push.sent.first?.alert == PushMessage.Alert(title: "Ada deleted", body: "Secret canary title"))
		}
	}

	// MARK: - Devices

	@Test func devicesWithASocketOpenGetNothing() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		let push = FakePush()

		try await withLiveServer(.sharing(scratch), push: push.sender) { app, server in
			let live = SyncLiveTests()
			let (phone, owner) = try await live.device(server, "owner")
			let (pad, _) = try await live.device(server, "owner")
			let (member, _) = try await live.device(server, "member")
			try await phone.registerPushDevice(token: "aa11")
			try await pad.registerPushDevice(token: "bb22")

			let heard = SyncLiveTests.Heard()
			let listening = heard.listen(phone)
			defer { listening.cancel() }
			#expect(try await eventually { app.ergo.live.count(of: owner.accountID) == 1 })

			let board = newBoardID()
			let statement = newBoardID()
			_ = try await pad.sync(SyncRequest(cursor: nil, changes: [
				boardChange(board, ["created": SyncField(value: 1, stamp: stamp(-20000))]),
				statementChange(statement, ["board": SyncField(value: .string(board), stamp: stamp(-20000))]),
			]))
			let invite = try await pad.createBoardInvite(board: board, CreateBoardInvite(role: .editor, title: "Board", name: "Ada"))
			_ = try await member.acceptBoardInvite(token: #require(BoardInviteLink.token(from: invite.url)), name: "Sam")
			_ = try await member.sync(SyncRequest(cursor: nil, changes: [
				statementChange(statement, ["content": SyncField(value: content("Edited"), stamp: stamp())]),
			]))

			#expect(try await eventually { push.sent.contains { $0.alert?.title == "Sam edited" } })
			#expect(push.sent.allSatisfy { $0.deviceToken == "bb22" })
		}
	}

	@Test func aDeadTokenDeletesTheDevice() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		let push = FakePush(outcome: .deviceGone)

		try await withTestApp(.sharing(scratch), push: push.sender) { app in
			let owner = try await app.signedInAccount("owner")
			let member = try await app.signedInAccount("member")
			try await app.registerPush("aa11", token: owner.token)
			let (board, _) = try await app.syncedBoard(owner: owner)
			let token = try await app.invite(board, token: owner.token)
			try await app.accept(token, token: member.token)

			#expect(try await eventually { push.sent.count == 1 })
			#expect(try await eventually { try await PushDeviceRow.query(on: app.db).count() == 0 })
		}
	}

	@Test func registeringReplacesWhatTheDeviceHad() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.sharing(scratch)) { app in
			let phone = try await app.signedInAccount("owner")
			let pad = try await app.signedInAccount("owner")
			let other = try await app.signedInAccount("someone-else")

			try await app.registerPush("AA11", token: phone.token)
			try await app.registerPush("aa11", token: phone.token)
			#expect(try await PushDeviceRow.query(on: app.db).all().map(\.apnsToken) == ["aa11"])

			// A new APNs token for this device
			try await app.registerPush("bb22", token: phone.token)
			#expect(try await PushDeviceRow.query(on: app.db).all().map(\.apnsToken) == ["bb22"])
			try await app.registerPush("cc33", token: pad.token)
			#expect(try await PushDeviceRow.query(on: app.db).count() == 2)

			// The same phone, signed in to another account
			try await app.registerPush("bb22", token: other.token)
			let moved = try #require(try await PushDeviceRow.query(on: app.db).filter(\.$apnsToken == "bb22").first())
			#expect(moved.$account.id == other.accountID)

			// Only this device's
			#expect(try await app.call(.DELETE, ErgoProtocol.Path.pushDevice, token: pad.token).status == .noContent)
			#expect(try await PushDeviceRow.query(on: app.db).all().map(\.apnsToken) == ["bb22"])

			// Signing out takes it with it
			#expect(try await app.call(.DELETE, ErgoProtocol.Path.accountToken, token: other.token).status == .noContent)
			#expect(try await PushDeviceRow.query(on: app.db).count() == 0)
		}
	}

	@Test(arguments: ["", "not hex", "../../etc", String(repeating: "a", count: 201)])
	func refusesATokenThatIsntHex(token: String) async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.sharing(scratch)) { app in
			let device = try await app.signedInAccount()
			let response = try await app.call(.PUT, ErgoProtocol.Path.pushDevice, token: device.token, body(PushDevice(token: token)))
			#expect(response.status == .badRequest)
		}
	}

	@Test func anonymousAccountsCantRegister() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.sharing(scratch)) { app in
			let account = try await app.createAccount()
			let response = try await app.call(.PUT, ErgoProtocol.Path.pushDevice, token: account.token, body(PushDevice(token: "aa11")))
			#expect(response.status == .forbidden)
		}
	}

	// MARK: - APNs

	@Test func thePayloadIsWhatApnsExpects() throws {
		let board = newBoardID()
		let alert = PushMessage(deviceToken: "aa11", board: board, alert: PushMessage.Alert(title: "Sam edited", body: "Rain"))
		let loud = try #require(try JSONSerialization.jsonObject(with: APNSClient.payload(for: alert)) as? [String: Any])
		let aps = try #require(loud["aps"] as? [String: Any])
		#expect(loud["board"] as? String == board)
		#expect(aps["alert"] as? [String: String] == ["title": "Sam edited", "body": "Rain"])
		#expect(aps["sound"] as? String == "default")
		#expect(aps["thread-id"] as? String == board)
		#expect(aps["content-available"] as? Int == 1)
		// It's the device's address, not something to tell it
		#expect(try !String(decoding: APNSClient.payload(for: alert), as: UTF8.self).contains("aa11"))

		let silent = PushMessage(deviceToken: "aa11", board: board, alert: nil)
		let quiet = try #require(try JSONSerialization.jsonObject(with: APNSClient.payload(for: silent)) as? [String: Any])
		#expect((quiet["aps"] as? [String: Any])?.keys.sorted() == ["content-available"])
	}

	@Test func theTokenIsSignedForApple() throws {
		let key = P256.Signing.PrivateKey()
		let token = try APNSClient.signedToken(key: key, keyID: "KEY", teamID: "TEAM", now: Date(timeIntervalSince1970: 1000))
		let parts = token.split(separator: ".").map(String.init)
		#expect(parts.count == 3)

		func decoded(_ part: String) throws -> Data {
			var base64 = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
			base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
			return try #require(Data(base64Encoded: base64))
		}

		let header = try JSONSerialization.jsonObject(with: decoded(parts[0])) as? [String: String]
		#expect(header == ["alg": "ES256", "kid": "KEY"])
		let claims = try JSONSerialization.jsonObject(with: decoded(parts[1])) as? [String: Any]
		#expect(claims?["iss"] as? String == "TEAM")
		#expect(claims?["iat"] as? Int == 1000)

		let signature = try P256.Signing.ECDSASignature(rawRepresentation: decoded(parts[2]))
		#expect(key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
	}

	@Test func noKeyMeansNoPushes() throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		let sender = PushSender.live(config: .testing(scratch), client: { nil }, logger: Logger(label: "test"))
		#expect(!sender.isEnabled)
	}

	@Test func readsTheKeyFromTheEnvironment() throws {
		let pem = P256.Signing.PrivateKey().pemRepresentation
		let vault = Data(repeating: 7, count: 32).base64EncodedString()
		let logger = Logger(label: "test")

		let config = try ServerConfig.load(from: [
			"ERGO_VAULT_KEY": vault,
			"ERGO_APNS_KEY": pem.replacingOccurrences(of: "\n", with: "\\n"),
			"ERGO_APNS_KEY_ID": "KEY",
			"ERGO_PUBLIC_URL": "https://example.com/",
			"ERGO_APPLE_TEAM_IDS": "AAA, BBB",
		], production: true, logger: logger)
		#expect(config.apns?.keyID == "KEY")
		#expect(config.apns?.teamID == "P6PV2R9443")
		#expect(config.apns?.topic == "com.adonis.Ergo")
		#expect(config.publicURL == "https://example.com")
		#expect(config.appleTeamIDs == ["AAA", "BBB"])

		#expect(throws: ServerConfig.Problem.self) {
			try ServerConfig.load(from: ["ERGO_VAULT_KEY": vault, "ERGO_APNS_KEY": "nonsense", "ERGO_APNS_KEY_ID": "KEY"], production: true, logger: logger)
		}
		#expect(throws: ServerConfig.Problem.self) {
			try ServerConfig.load(from: ["ERGO_VAULT_KEY": vault, "ERGO_APNS_KEY": pem], production: true, logger: logger)
		}
	}
}
