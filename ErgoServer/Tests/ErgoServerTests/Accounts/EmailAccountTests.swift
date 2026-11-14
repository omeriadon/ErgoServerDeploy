//
//  EmailAccountTests.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoClient
import ErgoProtocol
@testable import ErgoServer
import Fluent
import FluentSQLiteDriver
import Foundation
import Logging
import SQLKit
import Synchronization
import Testing
import Vapor
import VaporTesting

// MARK: - Helpers

extension Application {
	/// The status and raw body of a POST, whatever it was
	func post(_ path: String, token: String, _ value: some Encodable) async throws -> (status: HTTPResponseStatus, body: Data) {
		var result: (HTTPResponseStatus, Data)?
		try await testing().test(.POST, path, headers: .signedIn(token), body: body(value)) { response async throws in
			result = (response.status, Data(buffer: response.body))
		}
		return try #require(result)
	}

	func register(_ token: String, email: String = "ada@example.com", password: String = "correct horse") async throws -> (status: HTTPResponseStatus, body: Data) {
		try await post(ErgoProtocol.Path.register, token: token, EmailCredentials(email: email, password: password))
	}

	func logIn(_ token: String, email: String = "ada@example.com", password: String = "correct horse") async throws -> (status: HTTPResponseStatus, body: Data) {
		try await post(ErgoProtocol.Path.logIn, token: token, EmailCredentials(email: email, password: password))
	}

	func changePassword(_ token: String, current: String, new: String) async throws -> (status: HTTPResponseStatus, body: Data) {
		try await post(ErgoProtocol.Path.password, token: token, ChangePasswordRequest(current: current, new: new))
	}

	/// A new install that registered `email`
	func emailAccount(email: String = "ada@example.com", password: String = "correct horse") async throws -> AccountCreated {
		let account = try await createAccount()
		let (status, _) = try await register(account.token, email: email, password: password)
		#expect(status == .noContent)
		return account
	}

	/// A new install that logged in to the account of `email`, so it holds that account's second token
	func device(of email: String = "ada@example.com", password: String = "correct horse") async throws -> (token: String, signedIn: SignedIn) {
		let account = try await createAccount()
		let (status, data) = try await logIn(account.token, email: email, password: password)
		#expect(status == .ok)
		return try (account.token, ErgoProtocol.decoder.decode(SignedIn.self, from: data))
	}

	func status(of token: String) async throws -> HTTPResponseStatus {
		var status: HTTPResponseStatus?
		try await testing().test(.GET, ErgoProtocol.Path.connections, headers: .signedIn(token)) { response async throws in
			status = response.status
		}
		return try #require(status)
	}
}

func serviceError(_ body: Data) throws -> ServiceError {
	try ErgoProtocol.decoder.decode(ServiceError.self, from: body)
}

extension ServerConfig {
	static func testing(_ scratch: Scratch, loginFailures: Int? = nil, registrations: Int? = nil, trustProxy: Bool = false) -> ServerConfig {
		var config = ServerConfig.testing(scratch)
		config.failedLoginsPerWindow = loginFailures ?? config.failedLoginsPerWindow
		config.registrationsPerHour = registrations ?? config.registrationsPerHour
		config.trustProxy = trustProxy
		return config
	}
}

/// Bcrypt that remembers which hashes it was asked to check against
final class RecordingHasher: PasswordHasher {
	private let digests = Mutex<[String]>([])

	var checked: [String] {
		digests.withLock { $0 }
	}

	func hash(_ password: some DataProtocol) throws -> [UInt8] {
		try Array(Bcrypt.hash(String(decoding: Array(password), as: UTF8.self), cost: 4).utf8)
	}

	func verify(_ password: some DataProtocol, created digest: some DataProtocol) throws -> Bool {
		let digest = String(decoding: Array(digest), as: UTF8.self)
		digests.withLock { $0.append(digest) }
		return try Bcrypt.verify(String(decoding: Array(password), as: UTF8.self), created: digest)
	}
}

/// Everything the server logged, at any level
final class CapturedLogs: Sendable {
	private let lines = Mutex<[String]>([])

	var all: [String] {
		lines.withLock { $0 }
	}

	var logger: Logger {
		var logger = Logger(label: "captured") { _ in CapturingLogHandler(captured: self) }
		logger.logLevel = .trace
		return logger
	}

	fileprivate func add(_ line: String) {
		lines.withLock { $0.append(line) }
	}
}

struct CapturingLogHandler: LogHandler {
	let captured: CapturedLogs
	var metadata: Logger.Metadata = [:]
	var metadataProvider: Logger.MetadataProvider?
	var logLevel: Logger.Level = .trace

	subscript(metadataKey key: String) -> Logger.Metadata.Value? {
		get { metadata[key] }
		set { metadata[key] = newValue }
	}

	func log(event: LogEvent) {
		captured.add("\(event.level) \(event.message) \(event.metadata ?? [:]) \(metadata)")
	}
}

// MARK: - Registering

struct RegisterTests {
	@Test func attachesAnEmailAndPassword() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let account = try await app.createAccount()
			let other = try await app.createAccount()
			#expect(try await app.syncRefusal(SyncRequest(cursor: nil, changes: []), token: account.token).1.code == .signInRequired)

			let (status, body) = try await app.register(account.token, email: "  Ada@Example.COM ", password: "correct horse")
			#expect(status == .noContent)
			#expect(body.isEmpty)

			let stored = try #require(try await Account.find(account.id, on: app.db))
			#expect(stored.email == "ada@example.com")
			#expect(stored.isSignedIn)
			let hash = try #require(stored.passwordHash)
			#expect(hash.hasPrefix("$2"))
			#expect(!hash.contains("correct horse"))
			#expect(try Bcrypt.verify("correct horse", created: hash))

			// Signed in by email alone, so sync is open to it, and still shut to an anonymous account
			_ = try await app.sync(SyncRequest(cursor: nil, changes: []), token: account.token)
			#expect(try await app.syncRefusal(SyncRequest(cursor: nil, changes: []), token: other.token).1.code == .signInRequired)
			#expect(try await Account.find(other.id, on: app.db)?.email == nil)
		}
	}

	@Test func anEmailIsOnlyForOneAccount() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let first = try await app.emailAccount()
			let second = try await app.createAccount()

			let (status, body) = try await app.register(second.token, email: "ADA@example.com", password: "another horse")
			#expect(status == .conflict)
			#expect(try serviceError(body) == ServiceError(code: .emailInUse, message: "Expected an unused email, found one that has an account"))
			#expect(try await Account.find(second.id, on: app.db)?.email == nil)
			#expect(try await Account.find(first.id, on: app.db)?.email == "ada@example.com")
		}
	}

	@Test func anAccountHasOneEmail() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let account = try await app.emailAccount()
			let (status, body) = try await app.register(account.token, email: "other@example.com")
			#expect(status == .badRequest)
			#expect(try serviceError(body) == ServiceError(code: .invalidRequest, message: "Already signed in with an email, sign out first"))
			#expect(try await Account.find(account.id, on: app.db)?.email == "ada@example.com")
		}
	}

	@Test func bothIdentitiesCanBeAttached() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let apple = try await app.signedInAccount("apple-user")
			#expect(try await app.register(apple.token).status == .noContent)

			let stored = try #require(try await Account.find(apple.accountID, on: app.db))
			#expect(stored.appleSubject == "apple-user")
			#expect(stored.email == "ada@example.com")

			// Either way back in reaches it
			let viaEmail = try await app.device(of: "ada@example.com")
			let viaApple = try await app.signIn(app.createAccount().token, as: "apple-user")
			#expect(viaEmail.signedIn.accountID == apple.accountID)
			#expect(viaApple.accountID == apple.accountID)
		}
	}

	@Test(arguments: [
		("", "Expected an email like 'name@example.com', found ''"),
		("ada", "Expected an email like 'name@example.com', found 'ada'"),
		("ada@localhost", "Expected an email like 'name@example.com', found 'ada@localhost'"),
		("@example.com", "Expected an email like 'name@example.com', found '@example.com'"),
		("a@b@example.com", "Expected an email like 'name@example.com', found 'a@b@example.com'"),
		(String(repeating: "a", count: 250) + "@example.com", "Expected an email of at most 254 bytes, found 262"),
	])
	func malformedEmails(email: String, message: String) async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let account = try await app.createAccount()
			let (status, body) = try await app.register(account.token, email: email)
			#expect(status == .badRequest)
			#expect(try serviceError(body) == ServiceError(code: .invalidRequest, message: message))
			#expect(try await Account.find(account.id, on: app.db)?.email == nil)
		}
	}

	@Test(arguments: [
		("12345678", "Expected a password of 10 to 72 bytes, found 8"),
		("", "Expected a password of 10 to 72 bytes, found 0"),
		(String(repeating: "a", count: 73), "Expected a password of 10 to 72 bytes, found 73"),
		("ééééé", nil),
		(String(repeating: "a", count: 72), nil),
	])
	func passwordLength(password: String, message: String?) async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let account = try await app.createAccount()
			let (status, body) = try await app.register(account.token, password: password)

			if let message {
				#expect(status == .badRequest)
				#expect(try serviceError(body) == ServiceError(code: .invalidRequest, message: message))
				#expect(try await Account.find(account.id, on: app.db)?.passwordHash == nil)
			} else {
				#expect(status == .noContent)
			}
		}
	}

	@Test func registeringNeedsATokenAndABody() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			try await app.testing().test(.POST, ErgoProtocol.Path.register, headers: .version, body: body(StubCredentials)) { response async throws in
				#expect(response.status == .unauthorized)
				#expect(try response.decoded(ServiceError.self).code == .unauthorized)
			}

			let account = try await app.createAccount()
			try await app.testing().test(.POST, ErgoProtocol.Path.register, headers: .signedIn(account.token)) { response async throws in
				#expect(response.status == .badRequest)
			}
			try await app.testing().test(.POST, ErgoProtocol.Path.register, headers: .signedIn(account.token), body: ByteBuffer(string: #"{"email":1}"#)) { response async throws in
				#expect(try response.decoded(ServiceError.self) == ServiceError(code: .invalidRequest, message: "Couldn't read the request body"))
			}
		}
	}

	@Test func registeringIsLimitedPerAddress() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch, registrations: 2)) { app in
			let account = try await app.createAccount()
			#expect(try await app.register(account.token, password: "short").status == .badRequest)
			#expect(try await app.register(account.token).status == .noContent)

			let (status, body) = try await app.register(account.token, email: "other@example.com")
			#expect(status == .tooManyRequests)
			#expect(try serviceError(body) == ServiceError(code: .rateLimited, message: "Too many registrations from this address, try again in an hour"))
		}
	}
}

private let StubCredentials = EmailCredentials(email: "ada@example.com", password: "correct horse")

// MARK: - Logging in

struct LogInTests {
	@Test func mergesTheAnonymousAccountIntoTheOwnersAccount() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let owner = try await app.emailAccount()
			let anonymous = try await app.createAccount()
			try await app.storeCredential("sk-ant-oat-owner", provider: .claude, kind: .subscription, account: owner.id)
			try await app.storeCredential("sk-ant-oat-device", provider: .claude, kind: .subscription, account: anonymous.id)
			try await app.storeCredential("sk-device", provider: .codex, kind: .apiKey, account: anonymous.id)

			// Records an anonymous account can't normally have, written straight in
			let older = SyncField(value: content("Older"), stamp: stamp(-1000))
			let newer = SyncField(value: content("Newer"), stamp: stamp())
			let shared = newBoardID()
			let onlyHere = newBoardID()
			_ = try await app.sync(SyncRequest(cursor: nil, changes: [statementChange(shared, ["content": older])]), token: owner.token)
			for (seq, record) in [
				SyncRecord(kind: .statement, id: shared, fields: ["content": newer]),
				SyncRecord(kind: .statement, id: onlyHere, fields: ["content": older]),
			].enumerated() {
				let row = SyncRecordRow(account: anonymous.id, key: record.key)
				try row.store(record, seq: seq + 1, vault: app.ergo.vault)
				try await row.save(on: app.db)
			}

			// However it's spelled
			let (status, body) = try await app.logIn(anonymous.token, email: " ADA@example.com")
			#expect(status == .ok)
			#expect(try ErgoProtocol.decoder.decode(SignedIn.self, from: body) == SignedIn(accountID: owner.id, token: anonymous.token, isNewAccount: false))

			// The owner's connection stays, the device's fills the gap
			#expect(try await app.storedSecret(.claude, account: owner.id) == "sk-ant-oat-owner")
			#expect(try await app.storedSecret(.codex, account: owner.id) == "sk-device")
			#expect(try await Account.find(anonymous.id, on: app.db) == nil)
			#expect(try await AccountToken.query(on: app.db).filter(\.$account.$id == owner.id).count() == 2)

			let records = try await SyncRecordRow.query(on: app.db).sort(\.$seq).all()
			#expect(records.allSatisfy { $0.$account.id == owner.id })
			#expect(try records.map { try $0.record(app.ergo.vault) } == [
				SyncRecord(kind: .statement, id: shared, fields: ["content": newer]),
				SyncRecord(kind: .statement, id: onlyHere, fields: ["content": older]),
			])

			// The device's token now reaches the owner's account, which is signed in
			let pulled = try await app.sync(SyncRequest(cursor: nil, changes: []), token: anonymous.token)
			#expect(pulled.changes.map(\.id) == [shared, onlyHere])
		}
	}

	@Test func loggingInAgainChangesNothing() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let owner = try await app.emailAccount()
			let (status, body) = try await app.logIn(owner.token)
			#expect(status == .ok)
			#expect(try ErgoProtocol.decoder.decode(SignedIn.self, from: body) == SignedIn(accountID: owner.id, token: owner.token, isNewAccount: false))
			#expect(try await AccountToken.query(on: app.db).count() == 1)
		}
	}

	@Test func aWrongPasswordLooksLikeAnUnknownEmail() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			_ = try await app.emailAccount()
			let anonymous = try await app.createAccount()

			let wrong = try await app.logIn(anonymous.token, password: "wrong horse!")
			let unknown = try await app.logIn(anonymous.token, email: "nobody@example.com")
			let tooShort = try await app.logIn(anonymous.token, password: "x")
			let tooLong = try await app.logIn(anonymous.token, password: String(repeating: "correct horse", count: 8))

			for refusal in [wrong, unknown, tooShort, tooLong] {
				#expect(refusal.status == .unauthorized)
				// Key order isn't fixed, so compare what they say
				#expect(try serviceError(refusal.body) == serviceError(wrong.body))
			}
			let error = try serviceError(wrong.body)
			#expect(error == ServiceError(code: .invalidCredentials, message: "Expected the email and password of an account, found none that match"))
			// A dead token is something else, and the app signs out on it
			#expect(error.code != .unauthorized)

			// Nothing happened, and the token is still good
			#expect(try await Account.find(anonymous.id, on: app.db) != nil)
			#expect(try await app.status(of: anonymous.token) == .ok)
		}
	}

	@Test func aLongPasswordIsntCutShort() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			// bcrypt would match this against the 72 bytes it reads
			let password = String(repeating: "a", count: 72)
			_ = try await app.emailAccount(password: password)
			let anonymous = try await app.createAccount()

			#expect(try await app.logIn(anonymous.token, password: password + "b").status == .unauthorized)
			#expect(try await app.logIn(anonymous.token, password: password).status == .ok)
		}
	}

	@Test func anUnknownEmailIsCheckedAgainstADummyHash() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let recording = RecordingHasher()
			app.passwords.use { _ in recording }

			let owner = try await app.emailAccount()
			let hash = try #require(try await Account.find(owner.id, on: app.db)?.passwordHash)
			let anonymous = try await app.createAccount()
			#expect(recording.checked == [])

			_ = try await app.logIn(anonymous.token, password: "wrong horse!")
			_ = try await app.logIn(anonymous.token, email: "nobody@example.com")
			_ = try await app.logIn(anonymous.token, email: "nobody@example.com", password: "x")
			#expect(recording.checked == [hash, app.ergo.dummyPasswordHash, app.ergo.dummyPasswordHash])
			#expect(app.ergo.dummyPasswordHash != hash)
			#expect(app.ergo.dummyPasswordHash.hasPrefix("$2"))
		}
	}

	@Test func signedInAsSomeoneElseMustSignOutFirst() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let owner = try await app.emailAccount()
			let byEmail = try await app.emailAccount(email: "grace@example.com")
			let byApple = try await app.signedInAccount("apple-user")

			for token in [byEmail.token, byApple.token] {
				let (status, body) = try await app.logIn(token)
				#expect(status == .badRequest)
				#expect(try serviceError(body) == ServiceError(code: .invalidRequest, message: "Already signed in with another account, sign out first"))
			}
			#expect(try await Account.find(byEmail.id, on: app.db)?.email == "grace@example.com")
			#expect(try await Account.find(byApple.accountID, on: app.db) != nil)
			#expect(try await AccountToken.query(on: app.db).filter(\.$account.$id == owner.id).count() == 1)
		}
	}

	@Test func anEmailAccountCantJoinAnotherAppleID() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			_ = try await app.signedInAccount("apple-user")
			let byEmail = try await app.emailAccount()

			let request = try body(FakeApple.request(subject: "apple-user"))
			try await app.testing().test(.POST, ErgoProtocol.Path.appleSignIn, headers: .signedIn(byEmail.token), body: request) { response async throws in
				#expect(response.status == .badRequest)
				#expect(try response.decoded(ServiceError.self).message == "Expected an Apple ID without an Ergo account, found one with its own, sign out to use it")
			}
			#expect(try await Account.find(byEmail.id, on: app.db)?.email == "ada@example.com")

			// An Apple ID nobody has is fine, and makes it both
			_ = try await app.signIn(byEmail.token, as: "new-apple-user")
			#expect(try await Account.find(byEmail.id, on: app.db)?.appleSubject == "new-apple-user")
		}
	}

	@Test func theMergerWontDropAnEmail() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let first = try await app.emailAccount()
			let second = try await app.emailAccount(email: "grace@example.com")

			let target = try #require(try await Account.find(first.id, on: app.db))
			let source = try #require(try await Account.find(second.id, on: app.db))
			let token = try #require(try await AccountToken.query(on: app.db).filter(\.$account.$id == second.id).first())

			await #expect(throws: ServiceError(code: .invalidRequest, message: "Already signed in with an email, sign out first")) {
				try await app.db.transaction { database in
					try await AccountMerger(vault: app.ergo.vault, logger: app.logger).merge(source, into: target, token: token, on: database)
				}
			}
			#expect(try await Account.find(second.id, on: app.db)?.email == "grace@example.com")
			#expect(try await Account.find(first.id, on: app.db)?.email == "ada@example.com")
		}
	}

	@Test func signingOutTheLastDeviceKeepsTheAccount() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let owner = try await app.emailAccount()
			try await app.testing().test(.DELETE, ErgoProtocol.Path.accountToken, headers: .signedIn(owner.token)) { response async throws in
				#expect(response.status == .noContent)
			}
			#expect(try await Account.find(owner.id, on: app.db) != nil)
			#expect(try await app.device().signedIn.accountID == owner.id)
		}
	}

	@Test func deletingTheAccountFreesTheEmail() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let owner = try await app.emailAccount()
			try await app.testing().test(.DELETE, ErgoProtocol.Path.account, headers: .signedIn(owner.token)) { response async throws in
				#expect(response.status == .noContent)
			}
			#expect(try await Account.query(on: app.db).filter(\.$email == "ada@example.com").count() == 0)

			let again = try await app.emailAccount(password: "another horse")
			#expect(again.id != owner.id)
			#expect(try await app.logIn(app.createAccount().token, password: "correct horse").status == .unauthorized)
		}
	}
}

// MARK: - Changing the password

struct ChangePasswordTests {
	@Test func signsOutEveryOtherDeviceAndKeepsThisOne() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let phone = try await app.emailAccount()
			let pad = try await app.device()
			let mac = try await app.device()
			let someoneElse = try await app.emailAccount(email: "grace@example.com")
			#expect(try await AccountToken.query(on: app.db).filter(\.$account.$id == phone.id).count() == 3)

			let (status, body) = try await app.changePassword(pad.token, current: "correct horse", new: "another horse")
			#expect(status == .noContent)
			#expect(body.isEmpty)

			#expect(try await app.status(of: pad.token) == .ok)
			#expect(try await app.status(of: phone.token) == .unauthorized)
			#expect(try await app.status(of: mac.token) == .unauthorized)
			#expect(try await app.status(of: someoneElse.token) == .ok)
			#expect(try await AccountToken.query(on: app.db).filter(\.$account.$id == phone.id).count() == 1)

			// The new password logs in, the old one doesn't
			let fresh = try await app.createAccount()
			#expect(try await app.logIn(fresh.token, password: "correct horse").status == .unauthorized)
			#expect(try await app.logIn(fresh.token, password: "another horse").status == .ok)
			let hash = try #require(try await Account.find(phone.id, on: app.db)?.passwordHash)
			#expect(try Bcrypt.verify("another horse", created: hash))
		}
	}

	@Test func aWrongCurrentPasswordChangesNothing() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let phone = try await app.emailAccount()
			let pad = try await app.device()
			let before = try await Account.find(phone.id, on: app.db)?.passwordHash

			let (status, body) = try await app.changePassword(pad.token, current: "wrong horse!", new: "another horse")
			#expect(status == .unauthorized)
			#expect(try serviceError(body) == ServiceError(code: .invalidCredentials, message: "Expected the current password of this account, found another"))
			#expect(try await Account.find(phone.id, on: app.db)?.passwordHash == before)
			#expect(try await app.status(of: phone.token) == .ok)
		}
	}

	@Test func theNewPasswordHasTheSameRulesAsAnyOther() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let phone = try await app.emailAccount()
			let (status, body) = try await app.changePassword(phone.token, current: "correct horse", new: "12345678")
			#expect(status == .badRequest)
			#expect(try serviceError(body) == ServiceError(code: .invalidRequest, message: "Expected a password of 10 to 72 bytes, found 8"))
		}
	}

	@Test func anAccountWithoutAnEmailHasNoPassword() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let apple = try await app.signedInAccount()
			let (status, body) = try await app.changePassword(apple.token, current: "correct horse", new: "another horse")
			#expect(status == .badRequest)
			#expect(try serviceError(body).code == .invalidRequest)
		}
	}

	@Test func closesTheOtherDevicesSockets() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withLiveServer(.testing(scratch)) { app, server in
			let phone = try await ErgoClient(server: server, token: nil).createAccount()
			let phoneClient = ErgoClient(server: server, token: phone.token)
			try await phoneClient.register(email: "ada@example.com", password: "correct horse")

			let padAccount = try await ErgoClient(server: server, token: nil).createAccount()
			let padClient = ErgoClient(server: server, token: padAccount.token)
			let signedIn = try await padClient.logIn(email: "ada@example.com", password: "correct horse")
			#expect(signedIn.accountID == phone.id)

			let heard = (phone: SyncLiveTests.Heard(), pad: SyncLiveTests.Heard())
			let listening = [heard.phone.listen(phoneClient), heard.pad.listen(padClient)]
			defer { listening.forEach { $0.cancel() } }
			#expect(try await eventually { app.ergo.live.count(of: phone.id) == 2 })

			try await padClient.changePassword(current: "correct horse", new: "another horse")
			#expect(try await eventually { heard.phone.hasEnded && app.ergo.live.count(of: phone.id) == 1 })
			#expect(!heard.pad.hasEnded)

			await #expect(throws: ServiceError(code: .unauthorized, message: "Unknown Ergo account")) {
				try await phoneClient.changePassword(current: "another horse", new: "third horse!")
			}
			await #expect(throws: ServiceError(code: .invalidCredentials, message: "Expected the current password of this account, found another")) {
				try await padClient.changePassword(current: "correct horse", new: "third horse!")
			}
		}
	}
}

// MARK: - Brute force

struct BruteForceTests {
	@Test func failuresFromOneAddressAreLimited() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch, loginFailures: 3)) { app in
			_ = try await app.emailAccount()
			let anonymous = try await app.createAccount()

			// Different emails, so it's the address that runs out
			for index in 0 ..< 3 {
				#expect(try await app.logIn(anonymous.token, email: "nobody\(index)@example.com").status == .unauthorized)
			}

			// Even the right password has to wait now
			let (status, body) = try await app.logIn(anonymous.token)
			#expect(status == .tooManyRequests)
			let error = try serviceError(body)
			#expect(error.code == .rateLimited)
			#expect(error.message == "Too many failed sign-ins, try again in 15 minutes")
			#expect(try await Account.find(anonymous.id, on: app.db) != nil)
		}
	}

	@Test func successesDontCountAgainstTheLimit() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch, loginFailures: 3)) { app in
			let owner = try await app.emailAccount()
			for _ in 0 ..< 6 {
				#expect(try await app.logIn(owner.token).status == .ok)
			}
		}
	}

	@Test func wrongCurrentPasswordsCountToo() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch, loginFailures: 2)) { app in
			let owner = try await app.emailAccount()
			for _ in 0 ..< 2 {
				#expect(try await app.changePassword(owner.token, current: "wrong horse!", new: "another horse").status == .unauthorized)
			}
			let (status, body) = try await app.changePassword(owner.token, current: "correct horse", new: "another horse")
			#expect(status == .tooManyRequests)
			#expect(try serviceError(body).code == .rateLimited)
			#expect(try await app.logIn(owner.token).status == .tooManyRequests)
		}
	}

	@Test func limiterCountsAddressesAndEmailsSeparately() {
		let limiter = LoginLimiter(limit: 2, window: 60)
		let start = Date.now

		#expect(limiter.wait(address: "1.1.1.1", email: "a@example.com", now: start) == nil)
		limiter.fail(address: "1.1.1.1", email: "a@example.com", now: start)
		limiter.fail(address: "1.1.1.1", email: "b@example.com", now: start + 10)

		// The address is out whatever the email, the emails aren't
		#expect(limiter.wait(address: "1.1.1.1", email: "c@example.com", now: start + 20) == 40)
		#expect(limiter.wait(address: "2.2.2.2", email: "a@example.com", now: start + 20) == nil)

		// A second address on the first email fills it
		limiter.fail(address: "2.2.2.2", email: "a@example.com", now: start + 20)
		#expect(limiter.wait(address: "3.3.3.3", email: "a@example.com", now: start + 30) == 30)
		#expect(limiter.wait(address: "3.3.3.3", email: "b@example.com", now: start + 30) == nil)

		// The oldest failure going out of the window frees one slot
		#expect(limiter.wait(address: "1.1.1.1", email: "c@example.com", now: start + 50) == 10)
		#expect(limiter.wait(address: "1.1.1.1", email: "c@example.com", now: start + 61) == nil)
	}

	@Test func successForgetsTheEmailButNotTheAddress() {
		let limiter = LoginLimiter(limit: 1, window: 60)
		let start = Date.now
		limiter.fail(address: "1.1.1.1", email: "a@example.com", now: start)
		limiter.succeed(email: "a@example.com")

		#expect(limiter.wait(address: "2.2.2.2", email: "a@example.com", now: start) == nil)
		#expect(limiter.wait(address: "1.1.1.1", email: "b@example.com", now: start) == 60)
	}

	@Test func waitsAreWorded() {
		#expect(LoginLimiter.describe(wait: 0.2) == "1 second")
		#expect(LoginLimiter.describe(wait: 41.3) == "42 seconds")
		#expect(LoginLimiter.describe(wait: 60) == "1 minute")
		#expect(LoginLimiter.describe(wait: 61) == "2 minutes")
		#expect(LoginLimiter.describe(wait: 15 * 60) == "15 minutes")
	}
}

// MARK: - Behind a proxy

struct ClientAddressTests {
	@Test func directRequestsUseTheSocket() {
		for trust in [false, true] {
			#expect(ClientAddress.resolve(peer: "203.0.113.9", forwardedFor: ["198.51.100.1"], trustProxy: trust) == "203.0.113.9")
		}
		#expect(ClientAddress.resolve(peer: nil, forwardedFor: ["198.51.100.1"], trustProxy: true) == "unknown")
	}

	@Test func theHeaderIsIgnoredUnlessTrusted() {
		#expect(ClientAddress.resolve(peer: "127.0.0.1", forwardedFor: ["198.51.100.1"], trustProxy: false) == "127.0.0.1")
		#expect(ClientAddress.resolve(peer: "::1", forwardedFor: ["198.51.100.1"], trustProxy: false) == "::1")
	}

	@Test func theProxysOwnEntryIsTheLastOne() {
		#expect(ClientAddress.resolve(peer: "127.0.0.1", forwardedFor: ["198.51.100.1"], trustProxy: true) == "198.51.100.1")
		#expect(ClientAddress.resolve(peer: "::1", forwardedFor: ["2001:db8::7"], trustProxy: true) == "2001:db8::7")
		#expect(ClientAddress.resolve(peer: "::ffff:127.0.0.1", forwardedFor: ["198.51.100.1"], trustProxy: true) == "198.51.100.1")
	}

	@Test func whatTheClientWroteIsntBelieved() {
		// nginx appends to whatever the client sent, so only the last one is the proxy's
		#expect(ClientAddress.resolve(peer: "127.0.0.1", forwardedFor: ["10.0.0.1, 1.2.3.4, 198.51.100.1"], trustProxy: true) == "198.51.100.1")
		#expect(ClientAddress.resolve(peer: "127.0.0.1", forwardedFor: ["1.2.3.4", "198.51.100.1"], trustProxy: true) == "198.51.100.1")
	}

	@Test func localHopsAreSkipped() {
		#expect(ClientAddress.resolve(peer: "127.0.0.1", forwardedFor: ["198.51.100.1, 127.0.0.1"], trustProxy: true) == "198.51.100.1")
	}

	@Test(arguments: ["10.0.1.7", "172.18.0.3", "192.168.1.2", "fd12:3456::1", "::ffff:10.0.1.7"])
	func aProxyInAnotherContainerIsTrusted(peer: String) {
		#expect(ClientAddress.resolve(peer: peer, forwardedFor: ["198.51.100.1"], trustProxy: true) == "198.51.100.1")
		#expect(ClientAddress.resolve(peer: peer, forwardedFor: ["198.51.100.1"], trustProxy: false) == peer)
	}

	@Test(arguments: ["172.32.0.1", "192.169.0.1", "11.0.0.1", "2001:db8::7"])
	func aPublicPeerIsntTrusted(peer: String) {
		#expect(ClientAddress.resolve(peer: peer, forwardedFor: ["198.51.100.1"], trustProxy: true) == peer)
	}

	@Test func aMissingOrGarbledHeaderFallsBackToTheSocket() {
		#expect(ClientAddress.resolve(peer: "127.0.0.1", forwardedFor: [], trustProxy: true) == "127.0.0.1")
		#expect(ClientAddress.resolve(peer: "127.0.0.1", forwardedFor: ["1.2.3.4, not-an-address"], trustProxy: true) == "127.0.0.1")
		#expect(ClientAddress.resolve(peer: "127.0.0.1", forwardedFor: ["127.0.0.1"], trustProxy: true) == "127.0.0.1")
	}

	/// A POST to the live server, with the headers a proxy would add
	func post(_ server: URL, _ path: String, token: String? = nil, body: (any Encodable)? = nil, forwardedFor: String?) async throws -> (status: Int, body: Data) {
		var request = URLRequest(url: server.appending(path: path))
		request.httpMethod = "POST"
		request.setValue(String(ErgoProtocol.version), forHTTPHeaderField: ErgoProtocol.versionHeader)
		if let token {
			request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
		}
		if let forwardedFor {
			request.setValue(forwardedFor, forHTTPHeaderField: "X-Forwarded-For")
		}
		if let body {
			request.httpBody = try ErgoProtocol.encoder.encode(body)
		}
		let (data, response) = try await URLSession.shared.data(for: request)
		return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
	}

	@Test func eachClientBehindATrustedProxyHasItsOwnLimit() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch, trustProxy: true)
		config.accountsPerHour = 1

		try await withLiveServer(config) { _, server in
			let status1 = try await post(server, ErgoProtocol.Path.accounts, forwardedFor: "198.51.100.1").status
			#expect(status1 == 200)
			let status2 = try await post(server, ErgoProtocol.Path.accounts, forwardedFor: "198.51.100.2").status
			#expect(status2 == 200)
			let status3 = try await post(server, ErgoProtocol.Path.accounts, forwardedFor: "198.51.100.1").status
			#expect(status3 == 429)
			// Writing another address in front doesn't help
			let status4 = try await post(server, ErgoProtocol.Path.accounts, forwardedFor: "203.0.113.5, 198.51.100.1").status
			#expect(status4 == 429)
		}
	}

	@Test func withoutTrustEveryoneSharesTheProxy() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch, trustProxy: false)
		config.accountsPerHour = 1

		try await withLiveServer(config) { _, server in
			let status5 = try await post(server, ErgoProtocol.Path.accounts, forwardedFor: "198.51.100.1").status
			#expect(status5 == 200)
			let status6 = try await post(server, ErgoProtocol.Path.accounts, forwardedFor: "198.51.100.2").status
			#expect(status6 == 429)
		}
	}

	@Test func oneEmailIsLimitedAcrossAddresses() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withLiveServer(.testing(scratch, loginFailures: 3, trustProxy: true)) { _, server in
			let account = try await ErgoClient(server: server, token: nil).createAccount()
			func attempt(_ email: String, from address: String) async throws -> Int {
				try await post(server, ErgoProtocol.Path.logIn, token: account.token, body: EmailCredentials(email: email, password: "wrong horse!"), forwardedFor: address).status
			}

			for index in 1 ... 3 {
				let status = try await attempt("target@example.com", from: "198.51.100.\(index)")
				#expect(status == 401)
			}
			// A fourth address is blocked at that email, and unblocked at another
			let blocked = try await attempt("target@example.com", from: "198.51.100.4")
			let unblocked = try await attempt("other@example.com", from: "198.51.100.4")
			#expect(blocked == 429)
			#expect(unblocked == 401)
		}
	}
}

// MARK: - Logs

struct EmailLogTests {
	@Test func secretsNeverReachTheLogs() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		// The email is one of the configured ones, in another case, so the account is verbose once it has it
		var config = ServerConfig.testing(scratch)
		config.verboseAccounts = ["Log.Canary@Example.com"]

		try await withLiveServer(config) { app, server in
			let logs = CapturedLogs()
			app.logger = logs.logger

			let email = "log.canary@example.com"
			let password = "canary horse battery"
			let changed = "another canary horse"

			let phone = try await ErgoClient(server: server, token: nil).createAccount()
			let phoneClient = ErgoClient(server: server, token: phone.token)
			try await phoneClient.register(email: email, password: password)
			let hash = try #require(try await Account.find(phone.id, on: app.db)?.passwordHash)

			let pad = try await ErgoClient(server: server, token: ErgoClient(server: server, token: nil).createAccount().token)
			await #expect(throws: ServiceError.self) {
				_ = try await pad.logIn(email: email, password: "wrong canary horse")
			}
			await #expect(throws: ServiceError.self) {
				_ = try await pad.logIn(email: "unknown.canary@example.com", password: password)
			}
			await #expect(throws: ServiceError.self) {
				_ = try await pad.logIn(email: "not an email", password: password)
			}
			_ = try await pad.logIn(email: email, password: password)
			try await pad.changePassword(current: password, new: changed)
			await #expect(throws: ServiceError.self) {
				try await pad.changePassword(current: password, new: changed)
			}
			// A taken email, from an install of its own
			let third = try await ErgoClient(server: server, token: ErgoClient(server: server, token: nil).createAccount().token)
			await #expect(throws: ServiceError.self) {
				try await third.register(email: email, password: password)
			}

			let newHash = try #require(try await Account.find(phone.id, on: app.db)?.passwordHash)
			let everything = logs.all.joined(separator: "\n")
			// The server did log, so an empty capture can't pass
			#expect(everything.contains("Registered an email"))
			#expect(everything.contains("Signed in with an email"))
			// A verbose account is logged by its id, and everyone else by a pseudonym that isn't it
			#expect(everything.contains(phone.id.uuidString))
			for secret in [email, "canary", password, changed, "wrong canary horse", hash, newHash, String(hash.dropFirst(7)), "not an email"] {
				#expect(!everything.contains(secret), "Expected the logs without '\(secret.prefix(12))…', found it")
			}
		}
	}
}

// MARK: - Migration

struct AddAccountEmailTests {
	@Test func existingAccountsKeepWorking() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch)
		config.databasePath = scratch.path("ergo.sqlite")

		let apple = UUID()
		let anonymous = UUID()
		let appleToken = Account.makeToken()
		let anonymousToken = Account.makeToken()
		let created = Date(timeIntervalSince1970: 1_790_000_000)

		// A database from before emails
		try await withApp(configure: { app in
			app.databases.use(.sqlite(.file(config.databasePath)), as: .sqlite)
			app.migrations.add(CreateAccount())
			app.migrations.add(CreateCredential())
			app.migrations.add(CreateAccountToken())
			app.migrations.add(MoveAccountTokens())
			app.migrations.add(CreateSyncRecord())
			try await app.autoMigrate()
		}) { app in
			let sql = try #require(app.db as? any SQLDatabase)
			for (id, subject, seq) in [(apple, "apple-user", 3), (anonymous, nil, 0)] as [(UUID, String?, Int)] {
				try await sql.raw("""
				INSERT INTO accounts (id, created, last_seen, apple_subject, seq, pruned_through)
				VALUES (\(bind: id), \(bind: created), \(bind: created), \(bind: subject), \(bind: seq), 0)
				""").run()
			}
			try await AccountToken(account: apple, tokenHash: Account.hash(appleToken), now: created).save(on: app.db)
			try await AccountToken(account: anonymous, tokenHash: Account.hash(anonymousToken), now: created).save(on: app.db)

			let sealed = try CredentialVault(key: config.vaultKey).seal(Secret("sk-ant-oat-old"), account: apple, provider: .claude)
			try await Credential(account: apple, provider: .claude, kind: .subscription, sealed: sealed, verified: created, problem: nil).save(on: app.db)
			let record = SyncRecord(kind: .setting, id: SyncedSetting.ditherEnabled.rawValue, fields: ["value": SyncField(value: true, stamp: stamp())])
			let row = SyncRecordRow(account: apple, key: record.key)
			try row.store(record, seq: 3, vault: CredentialVault(key: config.vaultKey))
			// Raw, since the model has columns later migrations add
			try await sql.raw("""
			INSERT INTO sync_records (id, account_id, kind, record_id, fields, seq, updated)
			VALUES (\(bind: UUID()), \(bind: apple), \(bind: row.kind), \(bind: row.recordID), \(bind: row.fields), 3, \(bind: row.updated))
			""").run()
		}

		try await withTestApp(config) { app in
			let sql = try #require(app.db as? any SQLDatabase)

			// What was there is untouched
			let account = try #require(try await Account.find(apple, on: app.db))
			#expect(account.appleSubject == "apple-user")
			#expect(account.seq == 3)
			#expect(account.created == created)
			#expect(account.email == nil)
			#expect(account.passwordHash == nil)
			#expect(account.isSignedIn)
			#expect(try await app.storedSecret(.claude, account: apple) == "sk-ant-oat-old")
			#expect(try await SyncRecordRow.query(on: app.db).count() == 1)
			#expect(try await SyncRecordRow.query(on: app.db).first()?.board == nil)
			#expect(try await AccountToken.query(on: app.db).count() == 2)
			#expect(try await app.status(of: appleToken) == .ok)
			#expect(try await Account.find(anonymous, on: app.db)?.isSignedIn == false)
			_ = try await app.sync(SyncRequest(cursor: nil, changes: []), token: appleToken)
			#expect(try await app.syncRefusal(SyncRequest(cursor: nil, changes: []), token: anonymousToken).1.code == .signInRequired)

			// An old account can add an email, and an old anonymous account can log in to it
			#expect(try await app.register(appleToken, email: "Ada@Example.com").status == .noContent)
			#expect(try await app.logIn(anonymousToken).status == .ok)
			#expect(try await Account.find(anonymous, on: app.db) == nil)
			#expect(try await AccountToken.query(on: app.db).filter(\.$account.$id == apple).count() == 2)

			// The index is what keeps an email to one account, the many NULLs before it were fine
			let other = UUID()
			try await sql.raw("""
			INSERT INTO accounts (id, created, last_seen, seq, pruned_through) VALUES (\(bind: other), \(bind: created), \(bind: created), 0, 0)
			""").run()
			await #expect(throws: (any Error).self) {
				try await sql.raw("UPDATE accounts SET email = 'ada@example.com' WHERE id = \(bind: other)").run()
			}

			// Foreign keys are on, so deleting still cascades
			#expect(try await sql.raw("PRAGMA foreign_keys").first()?.decode(column: "foreign_keys", as: Int.self) == 1)
			try await sql.raw("DELETE FROM accounts WHERE id = \(bind: apple)").run()
			#expect(try await Credential.query(on: app.db).count() == 0)
			#expect(try await SyncRecordRow.query(on: app.db).count() == 0)
			#expect(try await AccountToken.query(on: app.db).count() == 0)
		}
	}
}
