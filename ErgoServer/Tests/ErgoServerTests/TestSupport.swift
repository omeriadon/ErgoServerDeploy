//
//  TestSupport.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import Crypto
import ErgoProtocol
@testable import ErgoServer
import Fluent
import Foundation
import JWT
import Testing
import VaporTesting

// MARK: - Scratch

/// A directory per test for fake CLIs, what they leave behind, and run directories
struct Scratch {
	let root: URL

	init() throws {
		root = FileManager.default.temporaryDirectory.appending(path: "ergo-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
	}

	func path(_ name: String) -> String {
		root.appending(path: name).path
	}

	/// A shell script standing in for a CLI. The server gives it an empty environment, so it only knows what's written into it.
	func script(_ name: String, _ body: String) throws -> String {
		let path = path(name)
		try ("#!/bin/sh\n" + body).write(toFile: path, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
		return path
	}

	func read(_ name: String) -> String? {
		try? String(contentsOfFile: path(name), encoding: .utf8)
	}

	func remove() {
		try? FileManager.default.removeItem(at: root)
	}
}

// MARK: - Config

extension ServerConfig {
	static func testing(_ scratch: Scratch) -> ServerConfig {
		var config = ServerConfig(vaultKey: SymmetricKey(size: .bits256))
		config.databasePath = ":memory:"
		config.runsDirectory = scratch.root.appending(path: "runs", directoryHint: .isDirectory)
		config.claudePath = nil
		config.codexPath = nil
		config.stageTimeout = .seconds(10)
		config.pruneInterval = nil
		// bcrypt's minimum, so each test isn't a quarter second per password
		config.passwordCost = 4
		return config
	}
}

extension ConnectionVerifier {
	/// Accepts everything, without a CLI
	static let accepting = ConnectionVerifier { credential, _ in credential.secret }

	static func rejecting(_ failure: ProviderFailure) -> ConnectionVerifier {
		ConnectionVerifier { _, _ in throw failure }
	}
}

extension AppleTokenVerifier {
	/// Takes `FakeApple.token(subject:nonce:)` at its word, and checks notifications against `FakeApple.key`, without Apple
	static let fake = AppleTokenVerifier { identityToken, _ in
		let parts = identityToken.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
		guard parts.count == 2 else {
			throw ServiceError(code: .invalidRequest, message: "Couldn't verify the Sign in with Apple token")
		}
		return AppleIdentity(subject: parts[0], nonce: parts[1].isEmpty ? nil : parts[1])
	} notificationKeys: { _ in
		await JWTKeyCollection().add(ecdsa: FakeApple.key.publicKey, kid: FakeApple.keyID)
	}
}

/// Stands in for the identity tokens Apple signs
enum FakeApple {
	static func token(subject: String, nonce: String?) -> String {
		subject + "|" + (nonce.map(AppleTokenVerifier.hash(nonce:)) ?? "")
	}

	static func request(subject: String, nonce: String = UUID().uuidString) -> SignInWithAppleRequest {
		SignInWithAppleRequest(identityToken: token(subject: subject, nonce: nonce), nonce: nonce)
	}

	// MARK: - Notifications

	/// Stands in for Apple's signing key. ES256 rather than Apple's RS256, since it's quick to make.
	static let key = ES256PrivateKey()
	static let keyID: JWKIdentifier = "fake-apple"

	/// What Apple puts in `events`, `is_private_email` as a string like Apple sometimes sends it
	struct Events: Encodable {
		let type: String
		let sub: String
		var eventTime = Int64(Date.now.timeIntervalSince1970 * 1000)
		var email = "relay.canary@privaterelay.appleid.com"
		var isPrivateEmail = "true"

		enum CodingKeys: String, CodingKey {
			case type, sub, email
			case eventTime = "event_time"
			case isPrivateEmail = "is_private_email"
		}
	}

	/// A signed server-to-server notification, as Apple would post it
	static func notification(
		_ type: String,
		subject: String = "apple-user",
		id: String = UUID().uuidString,
		issuer: String = AppleNotification.issuer,
		audience: String = "com.adonis.Ergo",
		issued: Date = .now,
		events: String? = nil,
		signedWith signer: ES256PrivateKey = key
	) async throws -> String {
		let events = try events ?? String(decoding: JSONEncoder().encode(Events(type: type, sub: subject)), as: UTF8.self)
		let claims = AppleNotificationClaims(iss: IssuerClaim(value: issuer), aud: AudienceClaim(value: [audience]), iat: IssuedAtClaim(value: issued), jti: IDClaim(value: id), events: events)
		return try await JWTKeyCollection().add(ecdsa: signer, kid: keyID).sign(claims, kid: keyID)
	}
}

// MARK: - Fixtures

enum Fixture {
	static func data(_ name: String) throws -> Data {
		let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
		return try Data(contentsOf: url)
	}

	static func text(_ name: String) throws -> String {
		try String(decoding: data(name), as: UTF8.self)
	}
}

// MARK: - Apps

/// In memory, for REST
func withTestApp(
	_ config: ServerConfig,
	verifier: ConnectionVerifier = .accepting,
	apple: AppleTokenVerifier = .fake,
	push: PushSender? = nil,
	appleTokens: AppleRefreshTokens? = nil,
	_ body: (Application) async throws -> Void
) async throws {
	try await withApp(configure: { app in
		try await configure(app, config: config, verifier: verifier, apple: apple, push: push, appleTokens: appleTokens)
	}, body)
}

/// A real server on a free port, for the sockets
func withLiveServer(
	_ config: ServerConfig,
	verifier: ConnectionVerifier = .accepting,
	apple: AppleTokenVerifier = .fake,
	push: PushSender? = nil,
	_ body: (Application, URL) async throws -> Void
) async throws {
	try await withTestApp(config, verifier: verifier, apple: apple, push: push) { app in
		app.http.server.configuration.hostname = "127.0.0.1"
		app.http.server.configuration.port = 0
		try await app.server.start(address: nil)

		do {
			let port = try #require(app.http.server.shared.localAddress?.port)
			try await body(app, #require(URL(string: "http://127.0.0.1:\(port)")))
		} catch {
			await app.server.shutdown()
			throw error
		}
		await app.server.shutdown()
	}
}

extension HTTPHeaders {
	static let version: HTTPHeaders = [ErgoProtocol.versionHeader: String(ErgoProtocol.version)]

	static func signedIn(_ token: String) -> HTTPHeaders {
		var headers = version
		headers.bearerAuthorization = BearerAuthorization(token: token)
		return headers
	}
}

extension TestingHTTPResponse {
	func decoded<Value: Decodable>(_: Value.Type) throws -> Value {
		try ErgoProtocol.decoder.decode(Value.self, from: Data(buffer: body))
	}
}

extension Application {
	func createAccount() async throws -> AccountCreated {
		var created: AccountCreated?
		try await testing().test(.POST, ErgoProtocol.Path.accounts, headers: .version) { response async throws in
			#expect(response.status == .ok)
			created = try response.decoded(AccountCreated.self)
		}
		return try #require(created)
	}

	/// Skips the verifier, as if it had been connected earlier
	@discardableResult
	func storeCredential(_ secret: String, provider: Provider, kind: CredentialKind, account: UUID) async throws -> Credential {
		let sealed = try ergo.vault.seal(Secret(secret), account: account, provider: provider)
		let credential = Credential(account: account, provider: provider, kind: kind, sealed: sealed, verified: .now, problem: nil)
		try await credential.save(on: db)
		return credential
	}

	/// A new install's account, signed in with the Apple ID `subject`
	func signedInAccount(_ subject: String = "apple-user") async throws -> SignedIn {
		let account = try await createAccount()
		return try await signIn(account.token, as: subject)
	}

	func signIn(_ token: String, as subject: String) async throws -> SignedIn {
		var signedIn: SignedIn?
		let request = try body(FakeApple.request(subject: subject))
		try await testing().test(.POST, ErgoProtocol.Path.appleSignIn, headers: .signedIn(token), body: request) { response async throws in
			#expect(response.status == .ok)
			signedIn = try response.decoded(SignedIn.self)
		}
		return try #require(signedIn)
	}

	func storedSecret(_ provider: Provider, account: UUID) async throws -> String? {
		guard let credential = try await Credential.find(provider, for: account, on: db) else { return nil }
		return try ergo.vault.open(credential.sealed, account: account, provider: provider).value
	}
}

func body(_ value: some Encodable) throws -> ByteBuffer {
	try ByteBuffer(data: ErgoProtocol.encoder.encode(value))
}

/// Polls, since the server finishes some things just after the client hears about them
func eventually(within limit: Duration = .seconds(5), _ condition: () async throws -> Bool) async throws -> Bool {
	let deadline = ContinuousClock.now + limit
	while ContinuousClock.now < deadline {
		if try await condition() {
			return true
		}
		try await Task.sleep(for: .milliseconds(50))
	}
	return try await condition()
}

func isRunning(_ pid: Int32) -> Bool {
	kill(pid, 0) == 0
}
