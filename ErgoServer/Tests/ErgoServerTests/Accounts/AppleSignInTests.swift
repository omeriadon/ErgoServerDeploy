//
//  AppleSignInTests.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoProtocol
@testable import ErgoServer
import Fluent
import FluentSQLiteDriver
import Foundation
import SQLKit
import Testing
import VaporTesting

struct AppleSignInTests {
	func signIn(_ app: Application, _ token: String, _ request: SignInWithAppleRequest) async throws -> (HTTPResponseStatus, Data) {
		var result: (HTTPResponseStatus, Data)?
		try await app.testing().test(.POST, ErgoProtocol.Path.appleSignIn, headers: .signedIn(token), body: body(request)) { response async throws in
			result = (response.status, Data(buffer: response.body))
		}
		return try #require(result)
	}

	@Test func firstDeviceKeepsItsAccount() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let account = try await app.createAccount()
			let signedIn = try await app.signIn(account.token, as: "apple-user")

			#expect(signedIn == SignedIn(accountID: account.id, token: account.token, isNewAccount: true))
			#expect(try await Account.find(account.id, on: app.db)?.appleSubject == "apple-user")

			// Again on the same device changes nothing
			#expect(try await app.signIn(account.token, as: "apple-user") == SignedIn(accountID: account.id, token: account.token, isNewAccount: false))
		}
	}

	@Test func secondDeviceJoinsTheFirst() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let phone = try await app.createAccount()
			let pad = try await app.createAccount()
			try await app.storeCredential("sk-ant-oat-phone", provider: .claude, kind: .subscription, account: phone.id)
			try await app.storeCredential("sk-ant-oat-pad", provider: .claude, kind: .subscription, account: pad.id)
			try await app.storeCredential("sk-pad", provider: .codex, kind: .apiKey, account: pad.id)

			_ = try await app.signIn(phone.token, as: "apple-user")
			let signedIn = try await app.signIn(pad.token, as: "apple-user")
			#expect(signedIn == SignedIn(accountID: phone.id, token: pad.token, isNewAccount: false))

			// The first device's connection stays, the second's fills the gap
			#expect(try await app.storedSecret(.claude, account: phone.id) == "sk-ant-oat-phone")
			#expect(try await app.storedSecret(.codex, account: phone.id) == "sk-pad")
			#expect(try await Account.find(pad.id, on: app.db) == nil)
			#expect(try await Credential.query(on: app.db).count() == 2)

			try await app.testing().test(.GET, ErgoProtocol.Path.connections, headers: .signedIn(pad.token)) { response async throws in
				#expect(try response.decoded([ConnectionStatus].self).map(\.provider) == [.claude, .codex])
			}
		}
	}

	@Test func nonceMustMatch() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let account = try await app.createAccount()
			let replayed = SignInWithAppleRequest(identityToken: FakeApple.token(subject: "apple-user", nonce: "first"), nonce: "second")
			let missing = SignInWithAppleRequest(identityToken: FakeApple.token(subject: "apple-user", nonce: nil), nonce: "second")

			let (status, data) = try await signIn(app, account.token, replayed)
			#expect(status == .badRequest)
			#expect(try ErgoProtocol.decoder.decode(ServiceError.self, from: data) == ServiceError(
				code: .invalidRequest,
				message: "Expected the Sign in with Apple token for this sign-in, found another one"
			))

			let (_, missingData) = try await signIn(app, account.token, missing)
			#expect(try ErgoProtocol.decoder.decode(ServiceError.self, from: missingData).message == "Expected a nonce in the Sign in with Apple token")
			#expect(try await Account.find(account.id, on: app.db)?.appleSubject == nil)
		}
	}

	@Test func nonceIsHashedLikeTheApp() {
		// What CryptoKit's SHA256 of "nonce" gives, as lowercase hex
		#expect(AppleTokenVerifier.hash(nonce: "nonce") == "78377b525757b494427f89014f97d79928f3938d14eb51e20fb5dec9834eb304")
	}

	@Test func rejectedTokens() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		let refusing = AppleTokenVerifier { _, _ in
			throw ServiceError(code: .invalidRequest, message: "Couldn't verify the Sign in with Apple token")
		}

		try await withTestApp(.testing(scratch), apple: refusing) { app in
			let account = try await app.createAccount()
			let (status, data) = try await signIn(app, account.token, FakeApple.request(subject: "apple-user"))
			#expect(status == .badRequest)
			#expect(try ErgoProtocol.decoder.decode(ServiceError.self, from: data).message == "Couldn't verify the Sign in with Apple token")
		}
	}

	@Test func anotherAppleIDNeedsSigningOutFirst() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let mine = try await app.signedInAccount("mine")
			_ = try await app.signedInAccount("theirs")

			for subject in ["theirs", "new"] {
				let (status, data) = try await signIn(app, mine.token, FakeApple.request(subject: subject))
				#expect(status == .badRequest)
				#expect(try ErgoProtocol.decoder.decode(ServiceError.self, from: data).message == "Already signed in with another Apple ID, sign out first")
			}
			#expect(try await Account.find(mine.accountID, on: app.db)?.appleSubject == "mine")
		}
	}

	// MARK: - Merging

	@Test func mergerKeepsEverything() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let first = try await app.signedInAccount()
			let device = try await app.createAccount()
			try await app.storeCredential("sk-ant-api-device", provider: .claude, kind: .apiKey, account: device.id)

			let shared = newBoardID()
			let older = SyncField(value: content("Older"), stamp: stamp(-1000))
			let newer = SyncField(value: content("Newer"), stamp: stamp())
			let position = SyncField(value: ["x": 1, "y": 2], stamp: stamp(-2000))
			_ = try await app.sync(SyncRequest(cursor: nil, changes: [statementChange(shared, ["content": older])]), token: first.token)

			// Records an anonymous account can't normally have, written straight in
			let vault = app.ergo.vault
			let onlyHere = newBoardID()
			for (seq, record) in [
				SyncRecord(kind: .statement, id: shared, fields: ["content": newer, "position": position]),
				SyncRecord(kind: .statement, id: onlyHere, fields: ["content": older]),
			].enumerated() {
				let row = SyncRecordRow(account: device.id, key: record.key)
				try row.store(record, seq: seq + 1, vault: vault)
				try await row.save(on: app.db)
			}

			let target = try #require(try await Account.find(first.accountID, on: app.db))
			let source = try #require(try await Account.find(device.id, on: app.db))
			let token = try #require(try await AccountToken.query(on: app.db).filter(\.$account.$id == device.id).first())
			let changed = try await app.db.transaction { database in
				try await AccountMerger(vault: vault, logger: app.logger).merge(source, into: target, token: token, on: database)
			}
			#expect(changed)

			let records = try await SyncRecordRow.query(on: app.db).sort(\.$seq).all()
			#expect(records.allSatisfy { $0.$account.id == first.accountID })
			#expect(try records.map { try $0.record(vault) } == [
				SyncRecord(kind: .statement, id: shared, fields: ["content": newer, "position": position]),
				SyncRecord(kind: .statement, id: onlyHere, fields: ["content": older]),
			])
			#expect(records.map(\.seq) == [2, 3])
			#expect(try await Account.find(first.accountID, on: app.db)?.seq == 3)

			#expect(try await app.storedSecret(.claude, account: first.accountID) == "sk-ant-api-device")
			#expect(try await AccountToken.query(on: app.db).filter(\.$account.$id == first.accountID).count() == 2)
			#expect(try await Account.find(device.id, on: app.db) == nil)

			// The device's old token now syncs the first account
			let pulled = try await app.sync(SyncRequest(cursor: nil, changes: []), token: device.token)
			#expect(pulled.changes.map(\.id) == [shared, onlyHere])
		}
	}

	// MARK: - Signing out and deleting

	@Test func signingOutForgetsOnlyThisDevice() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let phone = try await app.signedInAccount()
			let pad = try await app.signedInAccount()

			try await app.testing().test(.DELETE, ErgoProtocol.Path.accountToken, headers: .signedIn(phone.token)) { response async throws in
				#expect(response.status == .noContent)
			}
			try await app.testing().test(.GET, ErgoProtocol.Path.connections, headers: .signedIn(phone.token)) { response async throws in
				#expect(response.status == .unauthorized)
			}
			_ = try await app.sync(SyncRequest(cursor: nil, changes: []), token: pad.token)
			#expect(try await Account.find(phone.accountID, on: app.db) != nil)

			// The last device going leaves the account, which signing in again reaches
			try await app.testing().test(.DELETE, ErgoProtocol.Path.accountToken, headers: .signedIn(pad.token)) { response async throws in
				#expect(response.status == .noContent)
			}
			#expect(try await Account.find(phone.accountID, on: app.db) != nil)
			#expect(try await app.signedInAccount().accountID == phone.accountID)
		}
	}

	@Test func signingOutAnonymouslyDeletesTheAccount() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let account = try await app.createAccount()
			try await app.storeCredential("sk-ant-oat-fake", provider: .claude, kind: .subscription, account: account.id)

			try await app.testing().test(.DELETE, ErgoProtocol.Path.accountToken, headers: .signedIn(account.token)) { response async throws in
				#expect(response.status == .noContent)
			}
			#expect(try await Account.find(account.id, on: app.db) == nil)
			#expect(try await Credential.query(on: app.db).count() == 0)
		}
	}

	@Test func deletingTheAccountDeletesEverything() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let phone = try await app.signedInAccount()
			let pad = try await app.signedInAccount()
			let other = try await app.signedInAccount("someone-else")
			try await app.storeCredential("sk-ant-oat-fake", provider: .claude, kind: .subscription, account: phone.accountID)
			for device in [phone, other] {
				_ = try await app.sync(SyncRequest(cursor: nil, changes: [
					statementChange(newBoardID(), ["content": SyncField(value: content("Mine"), stamp: stamp())]),
				]), token: device.token)
			}

			try await app.testing().test(.DELETE, ErgoProtocol.Path.account, headers: .signedIn(pad.token)) { response async throws in
				#expect(response.status == .noContent)
			}

			for token in [phone.token, pad.token] {
				try await app.testing().test(.GET, ErgoProtocol.Path.connections, headers: .signedIn(token)) { response async throws in
					#expect(response.status == .unauthorized)
				}
			}
			#expect(try await Account.find(phone.accountID, on: app.db) == nil)
			#expect(try await AccountToken.query(on: app.db).filter(\.$account.$id == phone.accountID).count() == 0)
			#expect(try await SyncRecordRow.query(on: app.db).filter(\.$account.$id == phone.accountID).count() == 0)
			#expect(try await Credential.query(on: app.db).count() == 0)

			#expect(try await SyncRecordRow.query(on: app.db).filter(\.$account.$id == other.accountID).count() == 1)
			_ = try await app.sync(SyncRequest(cursor: nil, changes: []), token: other.token)

			// The Apple ID is free again, for a new account
			let again = try await app.signedInAccount()
			#expect(again.isNewAccount)
			#expect(again.accountID != phone.accountID)
		}
	}
}

// MARK: - Migration

struct MoveAccountTokensTests {
	@Test func existingTokensKeepWorking() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch)
		config.databasePath = scratch.path("ergo.sqlite")

		let id = UUID()
		let token = Account.makeToken()
		let created = Date(timeIntervalSince1970: 1_790_000_000)

		// A database from before tokens had their own table
		try await withApp(configure: { app in
			app.databases.use(.sqlite(.file(config.databasePath)), as: .sqlite)
			app.migrations.add(CreateAccount())
			app.migrations.add(CreateCredential())
			try await app.autoMigrate()
		}) { app in
			let sql = try #require(app.db as? any SQLDatabase)
			try await sql.raw("""
			INSERT INTO accounts (id, token_hash, created, last_seen) VALUES (\(bind: id), \(bind: Account.hash(token)), \(bind: created), \(bind: created))
			""").run()
			try await sql.raw("""
			INSERT INTO accounts (id, token_hash, created, last_seen) VALUES (\(bind: UUID()), \(bind: Account.hash("other")), \(bind: created), \(bind: created))
			""").run()
			let sealed = try CredentialVault(key: config.vaultKey).seal(Secret("sk-ant-oat-old"), account: id, provider: .claude)
			try await Credential(account: id, provider: .claude, kind: .subscription, sealed: sealed, verified: created, problem: nil).save(on: app.db)
		}

		try await withTestApp(config) { app in
			try await app.testing().test(.GET, ErgoProtocol.Path.connections, headers: .signedIn(token)) { response async throws in
				#expect(response.status == .ok)
				#expect(try response.decoded([ConnectionStatus].self).map(\.provider) == [.claude])
			}
			#expect(try await app.storedSecret(.claude, account: id) == "sk-ant-oat-old")

			let account = try #require(try await Account.find(id, on: app.db))
			#expect(account.created == created)
			#expect(account.seq == 0)
			#expect(account.appleSubject == nil)
			let tokens = try await AccountToken.query(on: app.db).all()
			#expect(tokens.count == 2)
			#expect(tokens.first { $0.$account.id == id }?.tokenHash == Account.hash(token))

			// Foreign keys are back on, so deleting still cascades
			let sql = try #require(app.db as? any SQLDatabase)
			#expect(try await sql.raw("PRAGMA foreign_keys").first()?.decode(column: "foreign_keys", as: Int.self) == 1)
			try await sql.raw("DELETE FROM accounts WHERE id = \(bind: id)").run()
			#expect(try await Credential.query(on: app.db).count() == 0)
			#expect(try await AccountToken.query(on: app.db).count() == 1)

			// And the new account path still works
			let fresh = try await app.signedInAccount()
			#expect(fresh.isNewAccount)
		}
	}
}
