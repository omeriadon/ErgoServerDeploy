//
//  AppleNotificationTests.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoProtocol
@testable import ErgoServer
import Fluent
import Foundation
import JWT
import Testing
import VaporTesting

// MARK: - Helpers

extension Application {
	/// Posts like Apple does: no token, no protocol version
	func notify(_ payload: String) async throws -> (status: HTTPResponseStatus, body: Data) {
		try await notify(body: ErgoServerTests.body(["payload": payload]))
	}

	func notify(body: ByteBuffer?, contentType: HTTPMediaType = .json) async throws -> (status: HTTPResponseStatus, body: Data) {
		var headers = HTTPHeaders()
		headers.contentType = contentType
		var result: (HTTPResponseStatus, Data)?
		try await testing().test(.POST, AppleNotificationController.path, headers: headers, body: body) { response async throws in
			result = (response.status, Data(buffer: response.body))
		}
		return try #require(result)
	}

	func syncBoard(_ token: String) async throws -> String {
		let board = newBoardID()
		_ = try await sync(SyncRequest(cursor: nil, changes: [
			statementChange(board, ["content": SyncField(value: content("Mine"), stamp: stamp())]),
		]), token: token)
		return board
	}
}

// MARK: - Events

struct AppleNotificationTests {
	@Test func consentRevokedSignsEveryDeviceOut() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let phone = try await app.signedInAccount()
			let pad = try await app.signedInAccount()
			try await app.storeCredential("sk-ant-oat-fake", provider: .claude, kind: .subscription, account: phone.accountID)
			let board = try await app.syncBoard(phone.token)

			let (status, data) = try await app.notify(FakeApple.notification("consent-revoked"))
			#expect(status == .ok)
			#expect(data.isEmpty)

			for token in [phone.token, pad.token] {
				#expect(try await app.status(of: token) == .unauthorized)
			}
			#expect(try await AccountToken.query(on: app.db).count() == 0)

			// Everything else stays
			#expect(try await Account.find(phone.accountID, on: app.db)?.appleSubject == "apple-user")
			#expect(try await SyncRecordRow.query(on: app.db).count() == 1)
			#expect(try await app.storedSecret(.claude, account: phone.accountID) == "sk-ant-oat-fake")

			// So signing in with Apple again gets back to it
			let again = try await app.signedInAccount()
			#expect(again.accountID == phone.accountID)
			#expect(!again.isNewAccount)
			#expect(try await app.sync(SyncRequest(cursor: nil, changes: []), token: again.token).changes.map(\.id) == [board])
		}
	}

	@Test func accountDeleteRemovesAnAppleOnlyAccount() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let phone = try await app.signedInAccount()
			let pad = try await app.signedInAccount()
			let other = try await app.signedInAccount("someone-else")
			try await app.storeCredential("sk-ant-oat-fake", provider: .claude, kind: .subscription, account: phone.accountID)
			try await app.storeCredential("sk-ant-oat-other", provider: .claude, kind: .subscription, account: other.accountID)
			_ = try await app.syncBoard(phone.token)
			_ = try await app.syncBoard(other.token)

			let (status, data) = try await app.notify(FakeApple.notification("account-delete"))
			#expect(status == .ok)
			#expect(data.isEmpty)

			for token in [phone.token, pad.token] {
				#expect(try await app.status(of: token) == .unauthorized)
			}
			#expect(try await Account.find(phone.accountID, on: app.db) == nil)
			#expect(try await AccountToken.query(on: app.db).filter(\.$account.$id == phone.accountID).count() == 0)
			#expect(try await SyncRecordRow.query(on: app.db).filter(\.$account.$id == phone.accountID).count() == 0)
			#expect(try await Credential.query(on: app.db).filter(\.$account.$id == phone.accountID).count() == 0)

			// Nobody else's
			#expect(try await app.status(of: other.token) == .ok)
			#expect(try await SyncRecordRow.query(on: app.db).filter(\.$account.$id == other.accountID).count() == 1)
			#expect(try await app.storedSecret(.claude, account: other.accountID) == "sk-ant-oat-other")

			// Should the same sub ever sign in, it's somebody new
			let again = try await app.signedInAccount()
			#expect(again.isNewAccount)
			#expect(again.accountID != phone.accountID)
		}
	}

	@Test func accountDeleteKeepsAnAccountWithAnEmail() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let phone = try await app.signedInAccount()
			#expect(try await app.register(phone.token).status == .noContent)
			_ = try await app.syncBoard(phone.token)

			#expect(try await app.notify(FakeApple.notification("account-delete")).status == .ok)

			let account = try #require(try await Account.find(phone.accountID, on: app.db))
			#expect(account.appleSubject == nil)
			#expect(account.email == "ada@example.com")
			#expect(account.isSignedIn)
			#expect(try await app.status(of: phone.token) == .ok)
			#expect(try await SyncRecordRow.query(on: app.db).count() == 1)
			_ = try await app.sync(SyncRequest(cursor: nil, changes: []), token: phone.token)

			// The email still gets in, and the Apple ID no longer reaches the account
			#expect(try await app.device().signedIn.accountID == phone.accountID)
			let again = try await app.signedInAccount()
			#expect(again.isNewAccount)
			#expect(again.accountID != phone.accountID)
		}
	}

	@Test(arguments: ["email-enabled", "email-disabled", "something-new"])
	func otherEventsChangeNothing(type: String) async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let phone = try await app.signedInAccount()

			let (status, data) = try await app.notify(FakeApple.notification(type))
			#expect(status == .ok)
			#expect(data.isEmpty)
			#expect(try await app.status(of: phone.token) == .ok)
			#expect(try await Account.find(phone.accountID, on: app.db)?.appleSubject == "apple-user")
		}
	}

	@Test(arguments: ["consent-revoked", "account-delete"])
	func anUnknownAppleIDIsAcknowledged(type: String) async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let phone = try await app.signedInAccount()

			#expect(try await app.notify(FakeApple.notification(type, subject: "nobody")).status == .ok)
			#expect(try await app.status(of: phone.token) == .ok)
			#expect(try await Account.find(phone.accountID, on: app.db) != nil)
		}
	}

	@Test(arguments: ["consent-revoked", "account-delete"])
	func repeatingAnEventIsHarmless(type: String) async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let phone = try await app.signedInAccount()

			// Each with its own jti, like a second notification about the same thing
			for _ in 0 ..< 2 {
				#expect(try await app.notify(FakeApple.notification(type)).status == .ok)
			}
			#expect(try await app.status(of: phone.token) == .unauthorized)
		}
	}

	@Test func aReplayedNotificationChangesNothing() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let phone = try await app.signedInAccount()
			let revoked = try await FakeApple.notification("consent-revoked")
			#expect(try await app.notify(revoked).status == .ok)
			#expect(try await app.status(of: phone.token) == .unauthorized)

			// Signed in again since, which the same notification must not undo
			let again = try await app.signedInAccount()
			#expect(try await app.notify(revoked).status == .ok)
			#expect(try await app.status(of: again.token) == .ok)
		}
	}

	@Test(arguments: ["consent-revoked", "account-delete"])
	func liveSocketsAreClosed(type: String) async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withLiveServer(.testing(scratch)) { app, server in
			let (phone, account) = try await SyncLiveTests().device(server)
			let (pad, _) = try await SyncLiveTests().device(server)
			let (other, someoneElse) = try await SyncLiveTests().device(server, "someone-else")

			let heard = (phone: SyncLiveTests.Heard(), pad: SyncLiveTests.Heard(), other: SyncLiveTests.Heard())
			let listening = [heard.phone.listen(phone), heard.pad.listen(pad), heard.other.listen(other)]
			defer { listening.forEach { $0.cancel() } }
			#expect(try await eventually {
				app.ergo.live.count(of: account.accountID) == 2 && app.ergo.live.count(of: someoneElse.accountID) == 1
			})

			#expect(try await app.notify(FakeApple.notification(type)).status == .ok)
			#expect(try await eventually {
				heard.phone.hasEnded && heard.pad.hasEnded && app.ergo.live.count(of: account.accountID) == 0
			})
			#expect(!heard.other.hasEnded)
			#expect(app.ergo.live.count(of: someoneElse.accountID) == 1)
		}
	}
}

// MARK: - Verifying

struct AppleNotificationVerifyTests {
	enum Forgery: String, CaseIterable, Sendable {
		case otherKey, otherIssuer, otherAudience, tooOld, fromTheFuture, notAJWT, eventsNotJSON, eventsWithoutSubject, noID

		func payload() async throws -> String {
			let type = "consent-revoked"
			return switch self {
				case .otherKey: try await FakeApple.notification(type, signedWith: ES256PrivateKey())
				case .otherIssuer: try await FakeApple.notification(type, issuer: "https://appleid.example.com")
				case .otherAudience: try await FakeApple.notification(type, audience: "com.example.Other")
				case .tooOld: try await FakeApple.notification(type, issued: .now.addingTimeInterval(-25 * 60 * 60))
				case .fromTheFuture: try await FakeApple.notification(type, issued: .now.addingTimeInterval(60 * 60))
				case .notAJWT: "not.a.jwt"
				case .eventsNotJSON: try await FakeApple.notification(type, events: type)
				case .eventsWithoutSubject: try await FakeApple.notification(type, events: #"{"type":"consent-revoked"}"#)
				case .noID: try await FakeApple.notification(type, id: "")
			}
		}
	}

	@Test(arguments: Forgery.allCases)
	func refusedNotificationsChangeNothing(forgery: Forgery) async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let phone = try await app.signedInAccount()

			let (status, data) = try await app.notify(forgery.payload())
			#expect(status == .badRequest)
			#expect(try serviceError(data) == .invalidNotification)
			#expect(try await app.status(of: phone.token) == .ok)
		}
	}

	@Test func ageHasSomeLeeway() throws {
		func claims(issued: Date) -> AppleNotificationClaims {
			AppleNotificationClaims(
				iss: IssuerClaim(value: AppleNotification.issuer),
				aud: AudienceClaim(value: ["com.adonis.Ergo"]),
				iat: IssuedAtClaim(value: issued),
				jti: IDClaim(value: "id"),
				events: #"{"type":"account-delete","sub":"apple-user","event_time":1,"is_private_email":true}"#
			)
		}
		let now = Date(timeIntervalSince1970: 1_790_000_000)
		let accepted = [-23 * 60 * 60, 4 * 60] as [TimeInterval]
		let refused = [-25 * 60 * 60, 6 * 60] as [TimeInterval]

		for offset in accepted {
			let notification = try AppleNotification(claims(issued: now.addingTimeInterval(offset)), applicationIdentifier: "com.adonis.Ergo", now: now)
			#expect(notification.id == "id")
			#expect(notification.event == .accountDelete)
			#expect(notification.subject == "apple-user")
		}
		for offset in refused {
			#expect(throws: AppleNotification.Refusal.self) {
				try AppleNotification(claims(issued: now.addingTimeInterval(offset)), applicationIdentifier: "com.adonis.Ergo", now: now)
			}
		}
	}

	@Test func eventsAreReadTolerantly() throws {
		let now = Date.now
		for events in [
			#"{"type":"email-disabled","sub":"apple-user","event_time":"1730000000000","email":"a@b.c","is_private_email":"true"}"#,
			#"{"type":"email-enabled","sub":"apple-user","is_private_email":false}"#,
		] {
			let claims = AppleNotificationClaims(
				iss: IssuerClaim(value: AppleNotification.issuer),
				aud: AudienceClaim(value: ["com.adonis.Ergo"]),
				iat: IssuedAtClaim(value: now),
				jti: IDClaim(value: "id"),
				events: events
			)
			#expect(try AppleNotification(claims, applicationIdentifier: "com.adonis.Ergo", now: now).subject == "apple-user")
		}
	}

	@Test func seenNotificationsAreForgottenAfterTheWindow() {
		let seen = SeenNotifications(window: 60)
		let start = Date(timeIntervalSince1970: 1_790_000_000)

		#expect(seen.insert("a", now: start))
		#expect(!seen.insert("a", now: start.addingTimeInterval(59)))
		#expect(seen.insert("a", now: start.addingTimeInterval(61)))

		seen.forget("a")
		#expect(seen.insert("a", now: start.addingTimeInterval(62)))
		#expect(seen.window == 60)
		#expect(SeenNotifications().window == 25 * 60 * 60)
	}
}

// MARK: - The route

struct AppleNotificationRouteTests {
	@Test func theBodyMustHoldAPayload() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let bodies: [String?] = [nil, "", "{}", #"{"payload":""}"#, #"{"payload":42}"#, "payload"]
			for text in bodies {
				let (status, data) = try await app.notify(body: text.map { ByteBuffer(string: $0) })
				#expect(status == .badRequest, "Expected 400 for \(text ?? "no body")")
				#expect(try serviceError(data) == .invalidNotification)
			}

			let huge = #"{"payload":"\#(String(repeating: "a", count: 17 * 1024))"}"#
			let (status, data) = try await app.notify(body: ByteBuffer(string: huge))
			#expect(status == .payloadTooLarge)
			#expect(try serviceError(data) == ServiceError(code: .tooLarge, message: "Expected a notification under 16 KB, found 18 KB"))
		}
	}

	@Test func bigBodiesAreRefusedOnTheWire() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withLiveServer(.testing(scratch)) { _, server in
			func post(_ payload: String) async throws -> (status: Int, body: Data) {
				var request = URLRequest(url: server.appending(path: AppleNotificationController.path))
				request.httpMethod = "POST"
				request.setValue("application/json", forHTTPHeaderField: "Content-Type")
				request.httpBody = try JSONEncoder().encode(["payload": payload])
				let (data, response) = try await URLSession.shared.data(for: request)
				return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
			}

			let (status, data) = try await post(String(repeating: "a", count: 17 * 1024))
			#expect(status == 413)
			#expect(try serviceError(data).code == .tooLarge)

			// And a real one, without the protocol version, gets through
			#expect(try await post(FakeApple.notification("email-enabled")).status == 200)
		}
	}

	@Test func aFormBodyWorksToo() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let phone = try await app.signedInAccount()
			// A JWT is base64url and dots, so it needs no escaping in a form
			let form = try await "payload=" + FakeApple.notification("consent-revoked")
			let (status, data) = try await app.notify(body: ByteBuffer(string: form), contentType: .urlEncodedForm)
			#expect(status == .ok)
			#expect(data.isEmpty)
			#expect(try await app.status(of: phone.token) == .unauthorized)
		}
	}

	@Test func onlyThisRouteSkipsTheProtocolVersion() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			#expect(try await app.notify(FakeApple.notification("email-enabled")).status == .ok)

			for (method, path) in [(HTTPMethod.GET, AppleNotificationController.path), (.POST, ErgoProtocol.Path.accounts), (.POST, "v1/apple")] {
				try await app.testing().test(method, path) { response async throws in
					#expect(response.status == .upgradeRequired, "Expected 426 for \(method) \(path)")
					#expect(try response.decoded(ServiceError.self).code == .outdatedApp)
				}
			}

			// The app's header doesn't get in the way
			let payload = try await FakeApple.notification("email-enabled")
			try await app.testing().test(.POST, AppleNotificationController.path, headers: .version, body: body(["payload": payload])) { response async throws in
				#expect(response.status == .ok)
			}
		}
	}

	@Test func notificationsAreLimitedPerAddress() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch)
		config.appleNotificationsPerMinute = 2

		try await withTestApp(config) { app in
			for _ in 0 ..< 2 {
				#expect(try await app.notify(FakeApple.notification("email-enabled")).status == .ok)
			}
			let (status, data) = try await app.notify(FakeApple.notification("email-enabled"))
			#expect(status == .tooManyRequests)
			#expect(try serviceError(data).code == .rateLimited)
		}
	}

	@Test func theLogsNeverSayWho() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let subject = "001234.subject-canary.5678"
			let kept = "001234.kept-canary.5678"
			let signedIn = try await app.signedInAccount(subject)
			let withEmail = try await app.signedInAccount(kept)
			#expect(try await app.register(withEmail.token, email: "email.canary@example.com").status == .noContent)
			// This route has no account of its own, so a notification is only said for a verbose account it was about
			app.ergo.verbose.remember(signedIn.accountID)
			app.ergo.verbose.remember(withEmail.accountID)

			// Only from here, since signing in isn't what's tested
			let logs = CapturedLogs()
			app.logger = logs.logger

			var payloads: [String] = []
			for (type, sub) in [
				("email-enabled", subject), ("consent-revoked", subject), ("account-delete", subject),
				("account-delete", kept), ("brand-new-event", subject), ("consent-revoked", "nobody.canary"),
			] {
				let payload = try await FakeApple.notification(type, subject: sub)
				payloads.append(payload)
				#expect(try await app.notify(payload).status == .ok)
			}
			let forged = try await FakeApple.notification("consent-revoked", subject: subject, signedWith: ES256PrivateKey())
			#expect(try await app.notify(forged).status == .badRequest)
			payloads.append(forged)

			let everything = logs.all.joined(separator: "\n")
			// The server did log, so an empty capture can't pass
			for said in ["consent-revoked", "account-delete", "Unknown Apple notification", "brand-new-event", "matched", "Apple notification refused"] {
				#expect(everything.contains(said), "Expected the logs to say '\(said)'")
			}
			let parts = payloads.flatMap { $0.split(separator: ".").map(String.init) }
			for secret in [subject, kept, "canary", "privaterelay"] + parts {
				#expect(!everything.contains(secret), "Expected the logs without '\(secret.prefix(12))…', found it")
			}
		}
	}
}
