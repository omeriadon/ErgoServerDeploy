//
//  ErgoProtocolTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoLogic
import ErgoProtocol
import ErgoTranslation
import Foundation
import Testing

/// The server and the app are separate builds, so a change to any of these shapes has to fail loudly here first
struct ErgoProtocolTests {
	static let id = UUID(uuidString: "6F1C2E9A-3B4D-4E5F-8A9B-0C1D2E3F4A5B")!
	static let date = Date(timeIntervalSince1970: 1_793_836_800)

	static let status = ConnectionStatus(provider: .claude, kind: .subscription, verified: date, problem: nil)
	static let error = ServiceError(code: .notConnected, message: "Claude isn't connected")
	static let request = TranslateRequest(id: id, english: "It rains.", provider: .codex, letters: LogicLetters.defaults, grammarVersion: 1)

	/// Sorted keys, so the snapshot doesn't depend on encoder order
	func json(_ value: some Encodable) throws -> String {
		let encoder = ErgoProtocol.encoder
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		return try String(decoding: encoder.encode(value), as: UTF8.self)
	}

	func expectRoundTrip<Value: Codable & Equatable>(_ value: Value, _ snapshot: String) throws {
		#expect(try json(value) == snapshot)
		#expect(try ErgoProtocol.decoder.decode(Value.self, from: Data(snapshot.utf8)) == value)
	}

	// MARK: - REST

	@Test func accountCreated() throws {
		try expectRoundTrip(
			AccountCreated(id: Self.id, token: "secret"),
			#"{"id":"6F1C2E9A-3B4D-4E5F-8A9B-0C1D2E3F4A5B","token":"secret"}"#
		)
	}

	@Test func connectionUpload() throws {
		try expectRoundTrip(ConnectionUpload(kind: .apiKey, secret: "sk"), #"{"kind":"apiKey","secret":"sk"}"#)
	}

	@Test func connectionStatus() throws {
		try expectRoundTrip(Self.status, #"{"kind":"subscription","provider":"claude","verified":"2026-11-05T00:00:00Z"}"#)
		try expectRoundTrip(
			ConnectionStatus(provider: .codex, kind: .apiKey, verified: nil, problem: "Expected a valid API key"),
			#"{"kind":"apiKey","problem":"Expected a valid API key","provider":"codex"}"#
		)
	}

	@Test func serviceError() throws {
		try expectRoundTrip(Self.error, #"{"code":"notConnected","message":"Claude isn't connected"}"#)
		#expect(Self.error.localizedDescription == "Claude isn't connected")
	}

	// MARK: - Sockets

	@Test func deviceLoginMessages() throws {
		try expectRoundTrip(
			DeviceLoginMessage.code(url: #require(URL(string: "https://auth.openai.com/codex/device")), code: "ABCD-1234"),
			#"{"code":{"code":"ABCD-1234","url":"https://auth.openai.com/codex/device"}}"#
		)
		try expectRoundTrip(
			DeviceLoginMessage.connected(Self.status),
			#"{"connected":{"_0":{"kind":"subscription","provider":"claude","verified":"2026-11-05T00:00:00Z"}}}"#
		)
		try expectRoundTrip(
			DeviceLoginMessage.failed(Self.error),
			#"{"failed":{"_0":{"code":"notConnected","message":"Claude isn't connected"}}}"#
		)
	}

	@Test func translateClientMessages() throws {
		try expectRoundTrip(
			TranslateClientMessage.translate(Self.request),
			#"{"translate":{"_0":{"english":"It rains.","grammarVersion":1,"id":"6F1C2E9A-3B4D-4E5F-8A9B-0C1D2E3F4A5B","letters":["X","Y","Z","P","Q","R"],"provider":"codex","scope":"statement"}}}"#
		)
		try expectRoundTrip(TranslateClientMessage.cancel, #"{"cancel":{}}"#)
	}

	@Test func translateScopeAndDescriptors() throws {
		var request = Self.request
		request.descriptors = ["it rains", "", "", "", "", ""]
		request.scope = .argument
		try expectRoundTrip(
			TranslateClientMessage.translate(request),
			#"{"translate":{"_0":{"descriptors":["it rains","","","","",""],"english":"It rains.","grammarVersion":1,"id":"6F1C2E9A-3B4D-4E5F-8A9B-0C1D2E3F4A5B","letters":["X","Y","Z","P","Q","R"],"provider":"codex","scope":"argument"}}}"#
		)
	}

	/// An older app sends neither, and means one statement with nothing named
	@Test func olderRequestsDecodeAsStatements() throws {
		let old = #"{"english":"It rains.","grammarVersion":1,"id":"6F1C2E9A-3B4D-4E5F-8A9B-0C1D2E3F4A5B","letters":["X","Y","Z","P","Q","R"],"provider":"codex"}"#
		let decoded = try ErgoProtocol.decoder.decode(TranslateRequest.self, from: Data(old.utf8))
		#expect(decoded == Self.request)
		#expect(decoded.scope == .statement)
		#expect(decoded.descriptors == nil)
	}

	@Test func breakDownServerMessages() throws {
		let breakdown = ArgumentBreakdown(
			kind: .argument,
			premises: ["It rains"],
			conclusion: "the ground is wet",
			claims: [BreakdownStage.Output.Claim(meaning: "It rains", descriptor: "it rains")],
			descriptors: ["it rains", "", "", "", "", ""]
		)
		try expectRoundTrip(
			BreakDownServerMessage.finished(breakdown),
			#"{"finished":{"_0":{"claims":[{"descriptor":"it rains","meaning":"It rains"}],"conclusion":"the ground is wet","descriptors":["it rains","","","","",""],"issues":[],"kind":"argument","premises":["It rains"]}}}"#
		)
		try expectRoundTrip(
			BreakDownServerMessage.event(.started(step: .breakdown, attempt: 1)),
			#"{"event":{"_0":{"started":{"attempt":1,"step":"breakdown"}}}}"#
		)

		// The same bytes as a statement scope's, so a failure before the scope is known reaches either client
		let failure = #"{"failed":{"_0":{"code":"busy","message":"Already translating"}}}"#
		let error = ServiceError(code: .busy, message: "Already translating")
		#expect(try ErgoProtocol.decoder.decode(BreakDownServerMessage.self, from: Data(failure.utf8)) == .failed(error))
		#expect(try json(TranslateServerMessage.failed(error)) == failure)
	}

	@Test func translateServerMessages() throws {
		try expectRoundTrip(
			TranslateServerMessage.event(.started(step: .gate, attempt: 1)),
			#"{"event":{"_0":{"started":{"attempt":1,"step":"gate"}}}}"#
		)
		try expectRoundTrip(
			TranslateServerMessage.event(.foundClaims(premises: ["It rains"], conclusion: "", descriptors: ["it rains", "", "", "", "", ""])),
			#"{"event":{"_0":{"foundClaims":{"conclusion":"","descriptors":["it rains","","","","",""],"premises":["It rains"]}}}}"#
		)
		try expectRoundTrip(
			TranslateServerMessage.event(.drafted(entries: [.variable(1), .symbol("∧"), .variable(2)], attempt: 2)),
			#"{"event":{"_0":{"drafted":{"attempt":2,"entries":[{"variable":{"_0":1}},{"symbol":{"_0":"∧"}},{"variable":{"_0":2}}]}}}}"#
		)
		try expectRoundTrip(
			TranslateServerMessage.event(.retrying(problems: ["Expected statement after '→'"], attempt: 1)),
			#"{"event":{"_0":{"retrying":{"attempt":1,"problems":["Expected statement after '→'"]}}}}"#
		)
		try expectRoundTrip(
			TranslateServerMessage.finished(Translation(english: "X", entries: [.variable(1)], issues: [TranslationIssue(severity: .warning, message: "W")])),
			#"{"finished":{"_0":{"descriptors":["","","","","",""],"english":"X","entries":[{"variable":{"_0":1}}],"issues":[{"message":"W","severity":"warning"}]}}}"#
		)
		try expectRoundTrip(
			TranslateServerMessage.failed(ServiceError(code: .busy, message: "Already translating")),
			#"{"failed":{"_0":{"code":"busy","message":"Already translating"}}}"#
		)
	}

	// MARK: - Sync

	static let stamp = SyncStamp(time: 1_793_836_800_000, counter: 2, device: "iPhone")
	static let stampJSON = #"{"counter":2,"device":"iPhone","time":1793836800000}"#

	@Test func syncRequest() throws {
		let change = SyncChange(
			kind: .board,
			id: Self.id.uuidString,
			fields: ["content": SyncField(value: ["english": "It rains."], stamp: Self.stamp)],
			bases: ["content": SyncStamp(time: 1, counter: 0, device: "iPad")]
		)
		try expectRoundTrip(
			SyncRequest(cursor: 3, changes: [change], limit: 500),
			#"{"changes":[{"bases":{"content":{"counter":0,"device":"iPad","time":1}},"fields":{"content":{"stamp":"#
				+ Self.stampJSON
				+ #","value":{"english":"It rains."}}},"id":"6F1C2E9A-3B4D-4E5F-8A9B-0C1D2E3F4A5B","kind":"board"}],"cursor":3,"limit":500}"#
		)
		try expectRoundTrip(SyncRequest(cursor: nil, changes: []), #"{"changes":[]}"#)
	}

	@Test func syncResponse() throws {
		let response = SyncResponse(
			cursor: 7,
			changes: [SyncRecord(kind: .setting, id: SyncedSetting.ditherEnabled.rawValue, fields: ["value": SyncField(value: true, stamp: Self.stamp)])],
			more: false,
			superseded: [SupersededField(kind: .board, id: Self.id.uuidString, field: "content", lost: SyncField(value: ["english": "It snows."], stamp: Self.stamp))],
			serverTime: Self.date
		)
		try expectRoundTrip(
			response,
			#"{"changes":[{"fields":{"value":{"stamp":"# + Self.stampJSON + #","value":true}},"id":"ditherEnabled","kind":"setting"}],"#
				+ #""cursor":7,"more":false,"serverTime":"2026-11-05T00:00:00Z","#
				+ #""superseded":[{"field":"content","id":"6F1C2E9A-3B4D-4E5F-8A9B-0C1D2E3F4A5B","kind":"board","lost":{"stamp":"#
				+ Self.stampJSON + #","value":{"english":"It snows."}}}]}"#
		)
	}

	@Test func syncLiveMessages() throws {
		try expectRoundTrip(SyncLiveMessage.changed(cursor: 7), #"{"changed":{"cursor":7}}"#)
	}

	@Test func signInWithApple() throws {
		try expectRoundTrip(SignInWithAppleRequest(identityToken: "eyJ", nonce: "n0nce"), #"{"identityToken":"eyJ","nonce":"n0nce"}"#)
		try expectRoundTrip(
			SignInWithAppleRequest(identityToken: "eyJ", nonce: "n0nce", authorizationCode: "c1"),
			#"{"authorizationCode":"c1","identityToken":"eyJ","nonce":"n0nce"}"#
		)
		try expectRoundTrip(
			SignedIn(accountID: Self.id, token: "secret", isNewAccount: false),
			#"{"accountID":"6F1C2E9A-3B4D-4E5F-8A9B-0C1D2E3F4A5B","isNewAccount":false,"token":"secret"}"#
		)
	}

	@Test func emailCredentials() throws {
		try expectRoundTrip(EmailCredentials(email: "ada@example.com", password: "correct horse"), #"{"email":"ada@example.com","password":"correct horse"}"#)
		try expectRoundTrip(ChangePasswordRequest(current: "old password", new: "new password"), #"{"current":"old password","new":"new password"}"#)
	}

	@Test func emailErrors() throws {
		let codes: [ServiceError.Code] = [.invalidCredentials, .emailInUse]
		#expect(codes.map(\.rawValue) == ["invalidCredentials", "emailInUse"])
		try expectRoundTrip(
			ServiceError(code: .invalidCredentials, message: "Expected the email and password of an account, found none that match"),
			#"{"code":"invalidCredentials","message":"Expected the email and password of an account, found none that match"}"#
		)
	}

	@Test func syncErrors() throws {
		let codes: [ServiceError.Code] = [.signInRequired, .syncResetRequired, .rateLimited, .tooLarge]
		#expect(codes.map(\.rawValue) == ["signInRequired", "syncResetRequired", "rateLimited", "tooLarge"])
		try expectRoundTrip(
			ServiceError(code: .tooLarge, message: "Expected a board under 256 KB, found 300 KB"),
			#"{"code":"tooLarge","message":"Expected a board under 256 KB, found 300 KB"}"#
		)
	}

	// MARK: - Constants

	/// The server routes on these, so they can't drift
	@Test func pathsAndHeader() {
		#expect(ErgoProtocol.version == 1)
		#expect(ErgoProtocol.versionHeader == "Ergo-Protocol-Version")
		#expect(ErgoProtocol.Path.accounts == "v1/accounts")
		#expect(ErgoProtocol.Path.account == "v1/account")
		#expect(ErgoProtocol.Path.connections == "v1/connections")
		#expect(ErgoProtocol.Path.deviceLogin == "v1/connections/codex/device-login")
		#expect(ErgoProtocol.Path.translate == "v1/translate")
		#expect(Provider.allCases.map(\.rawValue) == ["claude", "codex", "openrouter"])
		#expect(TranslationStep.allCases.map(\.rawValue) == [GateStage.name, BreakdownStage.name, FormalizeStage.name, VerifyStage.name])
	}

	@Test func emailPaths() {
		#expect(ErgoProtocol.Path.register == "v1/account/register")
		#expect(ErgoProtocol.Path.logIn == "v1/account/login")
		#expect(ErgoProtocol.Path.password == "v1/account/password")
	}

	// MARK: - Shapes

	@Test(arguments: [
		("ada@example.com", "ada@example.com"),
		("  Ada.Lovelace@Example.COM\n", "ada.lovelace@example.com"),
		("ÄDA@BÜCHER.DE", "äda@bücher.de"),
		// Decomposed and precomposed spellings are one email
		("a\u{308}da@example.com", "äda@example.com"),
		("a+tag@sub.example.co.uk", "a+tag@sub.example.co.uk"),
	])
	func emailsAreNormalized(email: String, expected: String) throws {
		#expect(try AccountEmail.normalized(email) == expected)
	}

	@Test(arguments: ["", "ada", "ada@", "@example.com", "ada@example", "ada@@example.com", "a@b@example.com", "ada@.com", "ada@example.", "ada@a..com", "a da@example.com", "ada@exa mple.com", "ada\u{0}@example.com"])
	func malformedEmails(email: String) {
		#expect(throws: ServiceError.self) {
			try AccountEmail.normalized(email)
		}
	}

	@Test func emailLengthIsCountedInBytes() throws {
		let local = String(repeating: "a", count: AccountEmail.maxBytes - "@example.com".utf8.count)
		#expect(try AccountEmail.normalized(local + "@example.com").utf8.count == AccountEmail.maxBytes)
		#expect(throws: ServiceError(code: .invalidRequest, message: "Expected an email of at most 254 bytes, found 255")) {
			try AccountEmail.normalized("a" + local + "@example.com")
		}
		// 2 bytes each: under 254 characters, over 254 bytes
		#expect(throws: ServiceError.self) {
			try AccountEmail.normalized(String(repeating: "é", count: 130) + "@example.com")
		}
	}

	@Test func passwordLengthIsCountedInBytes() throws {
		try AccountPassword.check(String(repeating: "a", count: 10))
		try AccountPassword.check(String(repeating: "a", count: 72))
		// 5 characters, 10 bytes
		try AccountPassword.check("ééééé")

		#expect(throws: ServiceError(code: .invalidRequest, message: "Expected a password of 10 to 72 bytes, found 8")) {
			try AccountPassword.check("12345678")
		}
		#expect(throws: ServiceError(code: .invalidRequest, message: "Expected a password of 10 to 72 bytes, found 73")) {
			try AccountPassword.check(String(repeating: "a", count: 73))
		}
		#expect(throws: ServiceError(code: .invalidRequest, message: "Expected a password of 10 to 72 bytes, found 77")) {
			try AccountPassword.check(String(repeating: "🔐", count: 19) + "x")
		}
		#expect(throws: ServiceError(code: .invalidRequest, message: "Expected a password without NUL characters")) {
			try AccountPassword.check("password\u{0}12")
		}
	}

	@Test func syncPaths() {
		#expect(ErgoProtocol.Path.appleSignIn == "v1/account/apple")
		#expect(ErgoProtocol.Path.accountToken == "v1/account/token")
		#expect(ErgoProtocol.Path.sync == "v1/sync")
		#expect(ErgoProtocol.Path.syncLive == "v1/sync/live")
	}
}
