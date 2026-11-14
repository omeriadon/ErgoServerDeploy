//
//  AppleRevocationTests.swift
//  ErgoServer
//
//  Created by Adon Omeri on 10/11/2026.
//

import Crypto
import ErgoProtocol
@testable import ErgoServer
import Fluent
import Foundation
import Logging
import Synchronization
import Testing
import VaporTesting

/// Stands in for Apple's token and revoke calls, keeping what it was asked
final class FakeAppleTokens: Sendable {
	private struct State {
		var codes: [String] = []
		var revoked: [String] = []
	}

	private let state = Mutex(State())
	private let isEnabled: Bool
	private let failsExchange: Bool
	private let failsRevoke: Bool

	/// What Apple says the code belongs to. Nil says nothing.
	private let subject: String?

	init(isEnabled: Bool = true, failsExchange: Bool = false, failsRevoke: Bool = false, subject: String? = nil) {
		self.isEnabled = isEnabled
		self.failsExchange = failsExchange
		self.failsRevoke = failsRevoke
		self.subject = subject
	}

	/// The codes it was given
	var codes: [String] {
		state.withLock { $0.codes }
	}

	/// The refresh tokens it was asked to revoke
	var revoked: [String] {
		state.withLock { $0.revoked }
	}

	/// Each exchange gives `refresh-1`, `refresh-2` and so on
	var tokens: AppleRefreshTokens {
		AppleRefreshTokens(isEnabled: isEnabled) { [self] code in
			let count = state.withLock { state in
				state.codes.append(code)
				return state.codes.count
			}
			if failsExchange {
				throw AppleAuthClient.Refusal(description: "invalid_grant")
			}
			return AppleGrant(refreshToken: Secret("refresh-\(count)"), subject: subject)
		} revoke: { [self] token in
			state.withLock { $0.revoked.append(token.value) }
			if failsRevoke {
				throw AppleAuthClient.Refusal(description: "status 500")
			}
		}
	}
}

extension Application {
	/// Signs in with a code too, like the app does. Nothing is asserted about the answer.
	func signIn(_ token: String, as subject: String, code: String?) async throws -> TestingHTTPResponse {
		let nonce = UUID().uuidString
		let request = SignInWithAppleRequest(identityToken: FakeApple.token(subject: subject, nonce: nonce), nonce: nonce, authorizationCode: code)
		return try await call(.POST, ErgoProtocol.Path.appleSignIn, token: token, body(request))
	}

	/// What's stored for the account, opened
	func storedRefreshToken(account: UUID) async throws -> String? {
		guard let sealed = try await Account.find(account, on: db)?.appleRefreshToken else { return nil }
		return try ergo.vault.openAppleRefreshToken(sealed, account: account).value
	}
}

struct AppleRevocationTests {
	// MARK: - Signing in

	@Test func theCodeIsTradedAndTheRefreshTokenKeptSealed() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		let apple = FakeAppleTokens()

		try await withTestApp(.sharing(scratch), appleTokens: apple.tokens) { app in
			let account = try await app.createAccount()
			let response = try await app.signIn(account.token, as: "apple-user", code: "code-1")
			#expect(response.status == .ok)
			#expect(try response.decoded(SignedIn.self).accountID == account.id)

			#expect(apple.codes == ["code-1"])
			#expect(try await app.storedRefreshToken(account: account.id) == "refresh-1")

			let sealed = try #require(try await Account.find(account.id, on: app.db)?.appleRefreshToken)
			#expect(String(decoding: sealed, as: UTF8.self).contains("refresh-1") == false)
			// Only opens for the account it was sealed for
			#expect(throws: CredentialVault.Unreadable.self) {
				try app.ergo.vault.openAppleRefreshToken(sealed, account: UUID())
			}
		}
	}

	@Test func aFailedTradeStillSignsIn() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		let apple = FakeAppleTokens(failsExchange: true)

		try await withTestApp(.sharing(scratch), appleTokens: apple.tokens) { app in
			let account = try await app.createAccount()
			let response = try await app.signIn(account.token, as: "apple-user", code: "expired")
			#expect(response.status == .ok)
			#expect(try response.decoded(SignedIn.self) == SignedIn(accountID: account.id, token: account.token, isNewAccount: true))

			#expect(apple.codes == ["expired"])
			#expect(try await Account.find(account.id, on: app.db)?.appleSubject == "apple-user")
			#expect(try await app.storedRefreshToken(account: account.id) == nil)
		}
	}

	@Test func aCodeForAnotherAppleIDIsNotKept() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		let apple = FakeAppleTokens(subject: "someone-else")

		try await withTestApp(.sharing(scratch), appleTokens: apple.tokens) { app in
			let account = try await app.createAccount()
			#expect(try await app.signIn(account.token, as: "apple-user", code: "code-1").status == .ok)
			#expect(apple.codes == ["code-1"])
			#expect(try await app.storedRefreshToken(account: account.id) == nil)
		}
	}

	@Test func noCodeMeansNothingToTrade() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		let apple = FakeAppleTokens()

		try await withTestApp(.sharing(scratch), appleTokens: apple.tokens) { app in
			let account = try await app.createAccount()
			// An older app, and a code that isn't one
			#expect(try await app.signIn(account.token, as: "apple-user", code: nil).status == .ok)
			#expect(try await app.signIn(account.token, as: "apple-user", code: "").status == .ok)
			#expect(try await app.signIn(account.token, as: "apple-user", code: String(repeating: "c", count: 2049)).status == .ok)

			#expect(apple.codes.isEmpty)
			#expect(try await app.storedRefreshToken(account: account.id) == nil)
		}
	}

	@Test func noKeyMeansNothingIsCalled() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		let apple = FakeAppleTokens(isEnabled: false)

		try await withTestApp(.sharing(scratch), appleTokens: apple.tokens) { app in
			let account = try await app.createAccount()
			#expect(try await app.signIn(account.token, as: "apple-user", code: "code-1").status == .ok)
			#expect(try await app.call(.DELETE, ErgoProtocol.Path.account, token: account.token).status == .noContent)

			#expect(apple.codes.isEmpty)
			#expect(apple.revoked.isEmpty)
			#expect(try await Account.find(account.id, on: app.db) == nil)
		}
	}

	@Test func theServersOwnDefaultIsOffWithoutAKey() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		// No injected stand-in, and `ServerConfig.testing` has no key: signing in and deleting must not reach for Apple
		try await withTestApp(.sharing(scratch)) { app in
			#expect(!app.ergo.appleTokens.isEnabled)
			let account = try await app.createAccount()
			#expect(try await app.signIn(account.token, as: "apple-user", code: "code-1").status == .ok)
			#expect(try await app.storedRefreshToken(account: account.id) == nil)
			#expect(try await app.call(.DELETE, ErgoProtocol.Path.account, token: account.token).status == .noContent)
		}
	}

	// MARK: - Merging

	@Test func theSurvivingAccountKeepsOneAndTheNewestReplacesIt() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		let apple = FakeAppleTokens()

		try await withTestApp(.sharing(scratch), appleTokens: apple.tokens) { app in
			let phone = try await app.createAccount()
			#expect(try await app.signIn(phone.token, as: "apple-user", code: "code-1").status == .ok)

			// A second device joins the first's account without a code, so the first's token stays
			let pad = try await app.createAccount()
			let withoutCode = try await app.signIn(pad.token, as: "apple-user", code: nil)
			#expect(try withoutCode.decoded(SignedIn.self).accountID == phone.id)
			#expect(try await app.storedRefreshToken(account: phone.id) == "refresh-1")

			// A third one brings a code, which replaces it
			let watch = try await app.createAccount()
			let withCode = try await app.signIn(watch.token, as: "apple-user", code: "code-2")
			#expect(try withCode.decoded(SignedIn.self).accountID == phone.id)
			#expect(try await app.storedRefreshToken(account: phone.id) == "refresh-2")
			#expect(try await Account.query(on: app.db).all().filter { $0.appleRefreshToken != nil }.count == 1)
		}
	}

	@Test func mergingMovesATokenTheTargetLacks() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.sharing(scratch)) { app in
			let first = try await app.signedInAccount()
			let device = try await app.createAccount()
			let vault = app.ergo.vault

			// A token an anonymous account can't normally have, written straight in
			let source = try #require(try await Account.find(device.id, on: app.db))
			source.appleRefreshToken = try vault.seal(appleRefreshToken: Secret("refresh-device"), account: device.id)
			try await source.save(on: app.db)

			let target = try #require(try await Account.find(first.accountID, on: app.db))
			let token = try #require(try await AccountToken.query(on: app.db).filter(\.$account.$id == device.id).first())
			_ = try await app.db.transaction { database in
				try await AccountMerger(vault: vault, logger: app.logger).merge(source, into: target, token: token, on: database)
			}

			#expect(try await app.storedRefreshToken(account: first.accountID) == "refresh-device")
		}
	}

	// MARK: - Deleting

	@Test func deletingRevokesBeforeTheRowsGo() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		let apple = FakeAppleTokens()

		try await withTestApp(.sharing(scratch), appleTokens: apple.tokens) { app in
			let account = try await app.createAccount()
			#expect(try await app.signIn(account.token, as: "apple-user", code: "code-1").status == .ok)

			#expect(try await app.call(.DELETE, ErgoProtocol.Path.account, token: account.token).status == .noContent)
			#expect(apple.revoked == ["refresh-1"])
			#expect(try await Account.find(account.id, on: app.db) == nil)
		}
	}

	@Test func aFailedRevokeStillDeletes() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		let apple = FakeAppleTokens(failsRevoke: true)

		try await withTestApp(.sharing(scratch), appleTokens: apple.tokens) { app in
			let account = try await app.createAccount()
			#expect(try await app.signIn(account.token, as: "apple-user", code: "code-1").status == .ok)

			#expect(try await app.call(.DELETE, ErgoProtocol.Path.account, token: account.token).status == .noContent)
			#expect(apple.revoked == ["refresh-1"])
			#expect(try await Account.find(account.id, on: app.db) == nil)
		}
	}

	@Test func nobodyIsRevokedWhoNeverSentACode() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		let apple = FakeAppleTokens()

		try await withTestApp(.sharing(scratch), appleTokens: apple.tokens) { app in
			// Signed in before the code was sent, and an anonymous account
			let old = try await app.signedInAccount("old-user")
			let anonymous = try await app.createAccount()

			for token in [old.token, anonymous.token] {
				#expect(try await app.call(.DELETE, ErgoProtocol.Path.account, token: token).status == .noContent)
			}
			#expect(apple.revoked.isEmpty)
		}
	}

	@Test func signingOutRevokesNothing() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		let apple = FakeAppleTokens()

		try await withTestApp(.sharing(scratch), appleTokens: apple.tokens) { app in
			let account = try await app.createAccount()
			#expect(try await app.signIn(account.token, as: "apple-user", code: "code-1").status == .ok)
			#expect(try await app.call(.DELETE, ErgoProtocol.Path.accountToken, token: account.token).status == .noContent)

			#expect(apple.revoked.isEmpty)
			#expect(try await app.storedRefreshToken(account: account.id) == "refresh-1")
		}
	}

	// MARK: - Apple's side

	@Test func theClientSecretIsSignedForApple() throws {
		let key = P256.Signing.PrivateKey()
		let config = ServerConfig.AppleSignIn(key: key.pemRepresentation, keyID: "KEY", teamID: "TEAM")
		let secret = try AppleAuthClient.clientSecret(config: config, clientID: "com.adonis.Ergo", now: Date(timeIntervalSince1970: 1000))
		let parts = secret.split(separator: ".").map(String.init)
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
		#expect(claims?["sub"] as? String == "com.adonis.Ergo")
		#expect(claims?["aud"] as? String == "https://appleid.apple.com")
		#expect(claims?["iat"] as? Int == 1000)
		#expect(claims?["exp"] as? Int == 1000 + 300)

		let signature = try P256.Signing.ECDSASignature(rawRepresentation: decoded(parts[2]))
		#expect(key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
	}

	@Test func formsEscapeWhatWouldBreakThem() {
		#expect(AppleAuthClient.form([("code", "a+b&c=d"), ("grant_type", "authorization_code")]) == "code=a%2Bb%26c%3Dd&grant_type=authorization_code")
	}

	@Test func theSubjectComesOutOfTheIdToken() {
		// {"sub":"apple-user"} between a header and a signature that are never read
		#expect(AppleAuthClient.subject(of: "e30.eyJzdWIiOiJhcHBsZS11c2VyIn0.sig") == "apple-user")
		#expect(AppleAuthClient.subject(of: "nonsense") == nil)
		#expect(AppleAuthClient.subject(of: "e30.e30.sig") == nil)
	}

	// MARK: - Configuration

	@Test func readsTheKeyFromTheEnvironment() throws {
		let pem = P256.Signing.PrivateKey().pemRepresentation
		let vault = Data(repeating: 7, count: 32).base64EncodedString()
		let logger = Logger(label: "test")

		let config = try ServerConfig.load(from: [
			"ERGO_VAULT_KEY": vault,
			"ERGO_APPLE_SIGNIN_KEY": pem.replacingOccurrences(of: "\n", with: "\\n"),
			"ERGO_APPLE_SIGNIN_KEY_ID": "KEY",
		], production: true, logger: logger)
		#expect(config.appleSignIn?.keyID == "KEY")
		#expect(config.appleSignIn?.teamID == "P6PV2R9443")
		#expect(try ServerConfig.load(from: ["ERGO_VAULT_KEY": vault], production: true, logger: logger).appleSignIn == nil)

		let team = try ServerConfig.load(from: [
			"ERGO_VAULT_KEY": vault, "ERGO_APPLE_SIGNIN_KEY": pem, "ERGO_APPLE_SIGNIN_KEY_ID": "KEY", "ERGO_APPLE_SIGNIN_TEAM_ID": "TEAM",
		], production: true, logger: logger)
		#expect(team.appleSignIn?.teamID == "TEAM")

		#expect(throws: ServerConfig.Problem.self) {
			try ServerConfig.load(from: ["ERGO_VAULT_KEY": vault, "ERGO_APPLE_SIGNIN_KEY": "nonsense", "ERGO_APPLE_SIGNIN_KEY_ID": "KEY"], production: true, logger: logger)
		}
		#expect(throws: ServerConfig.Problem.self) {
			try ServerConfig.load(from: ["ERGO_VAULT_KEY": vault, "ERGO_APPLE_SIGNIN_KEY": pem], production: true, logger: logger)
		}
		#expect(throws: ServerConfig.Problem.self) {
			try ServerConfig.load(from: ["ERGO_VAULT_KEY": vault, "ERGO_APPLE_SIGNIN_KEY_FILE": "/nonexistent/key.p8"], production: true, logger: logger)
		}
	}

	@Test func aConfiguredKeyTurnsTheLiveClientOn() throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch)
		#expect(!AppleRefreshTokens.live(config: config).isEnabled)

		config.appleSignIn = ServerConfig.AppleSignIn(key: P256.Signing.PrivateKey().pemRepresentation, keyID: "KEY", teamID: "TEAM")
		#expect(AppleRefreshTokens.live(config: config).isEnabled)
	}
}
