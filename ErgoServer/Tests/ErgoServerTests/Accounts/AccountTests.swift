//
//  AccountTests.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoProtocol
@testable import ErgoServer
import Fluent
import Foundation
import Testing
import VaporTesting

struct AccountTests {
	@Test func createdAccountCanSignIn() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let account = try await app.createAccount()
			#expect(account.token.count == 43)

			let stored = try await AccountToken.query(on: app.db).filter(\.$account.$id == account.id).all()
			#expect(stored.map(\.tokenHash) == [Account.hash(account.token)])
			#expect(stored.first?.tokenHash != account.token)

			try await app.testing().test(.GET, ErgoProtocol.Path.connections, headers: .signedIn(account.token)) { response async throws in
				#expect(response.status == .ok)
				#expect(try response.decoded([ConnectionStatus].self) == [])
			}
		}
	}

	@Test(arguments: [nil, "not-a-token"])
	func unknownTokenIsUnauthorized(token: String?) async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			_ = try await app.createAccount()
			let headers: HTTPHeaders = token.map { .signedIn($0) } ?? .version

			try await app.testing().test(.GET, ErgoProtocol.Path.connections, headers: headers) { response async throws in
				#expect(response.status == .unauthorized)
				#expect(try response.decoded(ServiceError.self) == ServiceError(code: .unauthorized, message: "Unknown Ergo account"))
			}
		}
	}

	@Test func creatingIsRateLimited() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch)
		config.accountsPerHour = 2

		try await withTestApp(config) { app in
			_ = try await app.createAccount()
			_ = try await app.createAccount()

			try await app.testing().test(.POST, ErgoProtocol.Path.accounts, headers: .version) { response async throws in
				#expect(response.status == .tooManyRequests)
				#expect(try response.decoded(ServiceError.self).code == .usageLimit)
			}
		}
	}

	@Test func limiterForgetsOnceTheWindowPasses() {
		let limiter = CreateAccountLimiter(limit: 1, window: 60)
		let start = Date.now

		#expect(limiter.allow("1.2.3.4", now: start))
		#expect(!limiter.allow("1.2.3.4", now: start + 30))
		#expect(limiter.allow("5.6.7.8", now: start + 30))
		#expect(limiter.allow("1.2.3.4", now: start + 61))
	}

	@Test func deletingRemovesCredentialsToo() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let account = try await app.createAccount()
			let other = try await app.createAccount()
			try await app.storeCredential("sk-ant-oat-fake", provider: .claude, kind: .subscription, account: account.id)
			try await app.storeCredential("sk-ant-oat-other", provider: .claude, kind: .subscription, account: other.id)

			try await app.testing().test(.DELETE, ErgoProtocol.Path.account, headers: .signedIn(account.token)) { response async throws in
				#expect(response.status == .noContent)
			}

			#expect(try await Account.find(account.id, on: app.db) == nil)
			#expect(try await Credential.query(on: app.db).filter(\.$account.$id == account.id).count() == 0)
			#expect(try await Credential.query(on: app.db).filter(\.$account.$id == other.id).count() == 1)

			try await app.testing().test(.GET, ErgoProtocol.Path.connections, headers: .signedIn(account.token)) { response async throws in
				#expect(response.status == .unauthorized)
			}
		}
	}
}

struct VersionHeaderTests {
	@Test(arguments: [nil, "0", "one"])
	func olderVersionsAreOutdated(version: String?) async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let headers: HTTPHeaders = version.map { [ErgoProtocol.versionHeader: $0] } ?? [:]

			for path in [ErgoProtocol.Path.accounts, ErgoProtocol.Path.connections] {
				try await app.testing().test(path == ErgoProtocol.Path.accounts ? .POST : .GET, path, headers: headers) { response async throws in
					#expect(response.status == .upgradeRequired)
					#expect(try response.decoded(ServiceError.self) == ServiceError(
						code: .outdatedApp,
						message: "Expected Ergo with protocol 1 or later, update the app"
					))
				}
			}
		}
	}

	@Test func anAppAheadOfTheServerIsNotToldToUpdate() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let headers: HTTPHeaders = [ErgoProtocol.versionHeader: String(ErgoProtocol.version + 1)]
			try await app.testing().test(.POST, ErgoProtocol.Path.accounts, headers: headers) { response async throws in
				#expect(response.status == .badGateway)
				#expect(try response.decoded(ServiceError.self).code == .providerUnavailable)
			}
		}
	}

	@Test func theCurrentVersionIsNotToldToUpdate() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			try await app.testing().test(.POST, ErgoProtocol.Path.accounts, headers: .version) { response async throws in
				#expect(response.status.code < 300)
				#expect(response.headers.first(name: ErgoProtocol.updateHeader) == nil)
			}
		}
	}

	/// Two versions served at once, which the real constants can't show until there's a second protocol
	@Test func everyVersionFromTheMinimumIsServed() {
		let versions = ProtocolVersions(minimum: 2, recommended: 3, current: 4)

		#expect(versions.check(nil) == .tooOld)
		#expect(versions.check("one") == .tooOld)
		#expect(versions.check("1") == .tooOld)
		#expect(versions.check("2") == .served(version: 2, update: true))
		#expect(versions.check("3") == .served(version: 3, update: false))
		#expect(versions.check("4") == .served(version: 4, update: false))
		#expect(versions.check("5") == .tooNew(5))
	}

	@Test func unknownPathIsAServiceError() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			try await app.testing().test(.GET, "v1/nothing", headers: .version) { response async throws in
				#expect(response.status == .badRequest)
				#expect(try response.decoded(ServiceError.self).code == .invalidRequest)
			}
		}
	}
}
