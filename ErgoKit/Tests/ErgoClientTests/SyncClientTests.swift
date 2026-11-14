//
//  SyncClientTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

@testable import ErgoClient
import ErgoProtocol
import Foundation
import Testing

/// The sync calls end to end, against a stand-in server inside URLSession
struct SyncClientTests {
	static let server = URL(string: "https://ergo.example.com")!
	let client = ErgoClient(server: Self.server, token: StubServer.signedIn, session: StubServer.session)

	@Test func syncSendsTheChangesAndDecodesTheReply() async throws {
		let change = SyncChange(
			kind: .setting,
			id: SyncedSetting.ditherEnabled.rawValue,
			fields: ["value": SyncField(value: true, stamp: SyncStamp(time: 1, counter: 0, device: "A"))]
		)
		let response = try await client.sync(SyncRequest(cursor: 4, changes: [change]))

		#expect(response.cursor == 5)
		#expect(response.changes == [change.record])
		#expect(response.serverTime == StubServer.now)
	}

	@Test func syncingSignedOutThrowsTheServersError() async {
		let anonymous = ErgoClient(server: Self.server, token: "anonymous", session: StubServer.session)
		await #expect(throws: StubServer.signInRequired) {
			try await anonymous.sync(SyncRequest(cursor: nil, changes: []))
		}
	}

	@Test func signingInSendsTheIdentityTokenAndNonce() async throws {
		let signedIn = try await client.signInWithApple(identityToken: "eyJ", nonce: "nonce")
		#expect(signedIn == SignedIn(accountID: StubServer.account, token: StubServer.signedIn, isNewAccount: false))
	}

	/// The stub only answers `isNewAccount` when the code reached it
	@Test func signingInSendsTheAuthorizationCodeWhenThereIsOne() async throws {
		let signedIn = try await client.signInWithApple(identityToken: "eyJ", nonce: "nonce", authorizationCode: "code")
		#expect(signedIn == SignedIn(accountID: StubServer.account, token: StubServer.signedIn, isNewAccount: true))
	}

	@Test func signingOutDeletesThisDevicesToken() async throws {
		try await client.signOut()
	}

	@Test func theLiveSocketIsAtTheSyncPath() {
		let request = client.socketRequest(ErgoProtocol.Path.syncLive)
		#expect(request.url?.absoluteString == "wss://ergo.example.com/v1/sync/live")
		#expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer signed-in")
	}
}

// MARK: - Stub

/// Answers like the server's sync routes: sync echoes the pushed records back, so a round trip shows the body went out
final class StubServer: URLProtocol {
	static let signedIn = "signed-in"
	static let account = UUID(uuidString: "6F1C2E9A-3B4D-4E5F-8A9B-0C1D2E3F4A5B")!
	static let now = Date(timeIntervalSince1970: 1_793_836_800)
	static let signInRequired = ServiceError(code: .signInRequired, message: "Sign in to sync")
	static let invalidCredentials = ServiceError(code: .invalidCredentials, message: "Expected the email and password of an account, found none that match")
	static let emailInUse = ServiceError(code: .emailInUse, message: "Expected an unused email, found one that has an account")
	static let email = EmailCredentials(email: "ada@example.com", password: "correct horse")

	static var session: URLSession {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [StubServer.self]
		return URLSession(configuration: configuration)
	}

	override class func canInit(with _: URLRequest) -> Bool {
		true
	}

	override class func canonicalRequest(for request: URLRequest) -> URLRequest {
		request
	}

	override func startLoading() {
		let (status, body) = Self.reply(to: request)
		let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
		client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
		client?.urlProtocol(self, didLoad: body)
		client?.urlProtocolDidFinishLoading(self)
	}

	override func stopLoading() {}

	static func reply(to request: URLRequest) -> (Int, Data) {
		guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(signedIn)" else {
			return (403, json(signInRequired))
		}
		let body = request.httpBodyStream.map(read) ?? request.httpBody ?? Data()
		switch (request.httpMethod, request.url?.path()) {
			case ("POST", "/v1/sync"):
				guard let sync = try? ErgoProtocol.decoder.decode(SyncRequest.self, from: body) else { return (400, Data()) }
				return (200, json(SyncResponse(cursor: (sync.cursor ?? 0) + 1, changes: sync.changes.map(\.record), more: false, serverTime: now)))
			case ("POST", "/v1/account/apple"):
				guard let signIn = try? ErgoProtocol.decoder.decode(SignInWithAppleRequest.self, from: body),
				      signIn.identityToken == "eyJ", signIn.nonce == "nonce",
				      [nil, "code"].contains(signIn.authorizationCode)
				else { return (400, Data()) }
				// A new account says the code arrived
				return (200, json(SignedIn(accountID: account, token: signedIn, isNewAccount: signIn.authorizationCode != nil)))
			case ("POST", "/v1/account/register"):
				guard let credentials = try? ErgoProtocol.decoder.decode(EmailCredentials.self, from: body) else { return (400, Data()) }
				return credentials.email == email.email ? (409, json(emailInUse)) : (204, Data())
			case ("POST", "/v1/account/login"):
				guard let credentials = try? ErgoProtocol.decoder.decode(EmailCredentials.self, from: body) else { return (400, Data()) }
				// A wrong password is a 401 too, and the client has to tell it from a dead token by the code
				return credentials == email ? (200, json(SignedIn(accountID: account, token: signedIn, isNewAccount: false))) : (401, json(invalidCredentials))
			case ("POST", "/v1/account/password"):
				guard let change = try? ErgoProtocol.decoder.decode(ChangePasswordRequest.self, from: body) else { return (400, Data()) }
				return change.current == email.password ? (204, Data()) : (401, json(invalidCredentials))
			case ("DELETE", "/v1/account/token"):
				return (204, Data())
			default:
				return (404, Data())
		}
	}

	static func json(_ value: some Encodable) -> Data {
		(try? ErgoProtocol.encoder.encode(value)) ?? Data()
	}

	static func read(_ stream: InputStream) -> Data {
		stream.open()
		defer { stream.close() }
		var data = Data()
		var buffer = [UInt8](repeating: 0, count: 4096)
		while stream.hasBytesAvailable {
			let count = stream.read(&buffer, maxLength: buffer.count)
			guard count > 0 else { break }
			data.append(buffer, count: count)
		}
		return data
	}
}
