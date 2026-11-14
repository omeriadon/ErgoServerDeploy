//
//  LogTests.swift
//  ErgoServer
//
//  Created by Adon Omeri on 10/11/2026.
//

import ErgoProtocol
@testable import ErgoServer
import Foundation
import Logging
import Testing
import VaporTesting

extension CapturedLogs {
	/// What's on at the default level. Vapor's own trace lines print request heads, bearer token and all.
	var shown: [String] {
		all.filter { !$0.hasPrefix("trace") && !$0.hasPrefix("debug") }
	}
}

// MARK: - Who is verbose

struct VerboseAccountsTests {
	@Test func pseudonymsAreShortStableAndNotTheId() {
		let id = UUID()
		let pseudonym = VerboseAccounts.pseudonym(for: id)

		#expect(pseudonym.count == 8)
		#expect(pseudonym.allSatisfy(\.isHexDigit))
		#expect(pseudonym == VerboseAccounts.pseudonym(for: id))
		#expect(pseudonym != VerboseAccounts.pseudonym(for: UUID()))
		#expect(!id.uuidString.lowercased().contains(pseudonym))
	}

	@Test func emailsMatchInAnyCaseAndIdsMatchAsTheyAre() {
		let listed = UUID()
		let verbose = VerboseAccounts(["  Ada@Example.COM ", listed.uuidString.lowercased(), "not an email", ""])

		let ada = Account()
		ada.id = UUID()
		ada.email = "ada@example.com"
		let other = Account()
		other.id = UUID()
		other.email = "grace@example.com"
		let anonymous = Account()
		anonymous.id = UUID()

		#expect(verbose.resolve(ada))
		#expect(!verbose.resolve(other))
		#expect(!verbose.resolve(anonymous))
		#expect(verbose.isVerbose(listed))
		#expect(!verbose.isVerbose(UUID()))
	}

	@Test func whoIsVerboseIsRememberedForWorkWithOnlyAnId() {
		let verbose = VerboseAccounts(["ada@example.com"])
		let id = UUID()
		#expect(!verbose.isVerbose(id))

		// An email can be attached after launch
		#expect(verbose.resolve(email: "Ada@example.com", of: id))
		#expect(verbose.isVerbose(id))
		#expect(!verbose.resolve(email: "grace@example.com", of: UUID()))
	}

	@Test func nothingConfiguredMeansNobody() {
		let verbose = VerboseAccounts([])
		let account = Account()
		account.id = UUID()
		account.email = "ada@example.com"

		#expect(verbose.isEmpty)
		#expect(!verbose.resolve(account))
		#expect(!verbose.isVerbose(account.id ?? UUID()))
	}
}

// MARK: - Loggers

struct AccountLoggerTests {
	@Test func aVerboseAccountIsLoggedByItsId() {
		let logs = CapturedLogs()
		let id = UUID()
		let verbose = VerboseAccounts([id.uuidString])
		let logger = verbose.logger(for: id, from: logs.logger)

		logger.verbose("Did something", metadata: ["count": "3"])
		logger.warning("Went wrong")

		let lines = logs.shown
		#expect(logger.isVerbose)
		#expect(lines.count == 2)
		#expect(lines.allSatisfy { $0.contains(id.uuidString) })
		#expect(lines.first?.hasPrefix("info Did something") == true)
	}

	@Test func anyoneElseOnlyHasProblemsAndOnlyAPseudonym() {
		let logs = CapturedLogs()
		let id = UUID()
		let verbose = VerboseAccounts(["someone.else@example.com"])
		let logger = verbose.logger(for: id, from: logs.logger)

		logger.verbose("Did something")
		logger.info("Did something else")
		logger.notice("Did a third thing")
		logger.warning("Went wrong")
		logger.error("Went very wrong")

		let lines = logs.shown
		#expect(!logger.isVerbose)
		#expect(lines.count == 2)
		#expect(lines.allSatisfy { $0.contains(VerboseAccounts.pseudonym(for: id)) })
		#expect(lines.allSatisfy { !$0.contains(id.uuidString) })
	}

	@Test func aLoggerNeverMadeForAnAccountSaysNothingVerbose() {
		let logs = CapturedLogs()
		logs.logger.verbose("Did something")

		#expect(logs.shown.isEmpty)
		#expect(!logs.logger.isVerbose)
	}

	@Test func anotherAccountsIdIsReplacedNeverKept() {
		let logs = CapturedLogs()
		let ada = UUID()
		let grace = UUID()
		let verbose = VerboseAccounts([ada.uuidString])

		// A push to Grace caused by Ada's change is Grace's warning
		let adas = verbose.logger(for: ada, from: logs.logger)
		verbose.logger(for: grace, from: adas).warning("Couldn't send a push")

		let line = logs.shown.joined(separator: "\n")
		#expect(line.contains(VerboseAccounts.pseudonym(for: grace)))
		#expect(!line.contains(ada.uuidString))
		#expect(!line.contains(grace.uuidString))
	}

	@Test func errorsOnlyShowTheirDetailsToAVerboseAccount() {
		struct Quoting: Error, CustomStringConvertible, CustomDebugStringConvertible {
			var description: String {
				"duplicate key value (email)=(canary@example.com)"
			}

			var debugDescription: String {
				description
			}
		}

		let id = UUID()
		let logs = CapturedLogs()
		let verbose = VerboseAccounts([id.uuidString])
		let other = VerboseAccounts([])

		#expect(verbose.logger(for: id, from: logs.logger).reason(for: Quoting()).contains("canary@example.com"))
		#expect(!other.logger(for: id, from: logs.logger).reason(for: Quoting()).contains("canary@example.com"))
		#expect(other.logger(for: id, from: logs.logger).reason(for: Quoting()) == "Quoting")
	}
}

// MARK: - Throttle

struct LogThrottleTests {
	@Test func saysOnceAWindowAndCountsTheRest() {
		let throttle = LogThrottle(window: 60)
		let start = Date(timeIntervalSince1970: 1_800_000_000)

		#expect(throttle.allow("a", now: start) == 0)
		#expect(throttle.allow("a", now: start.addingTimeInterval(1)) == nil)
		#expect(throttle.allow("a", now: start.addingTimeInterval(30)) == nil)
		#expect(throttle.allow("b", now: start.addingTimeInterval(30)) == 0)
		#expect(throttle.allow("a", now: start.addingTimeInterval(61)) == 2)
		#expect(throttle.allow("a", now: start.addingTimeInterval(62)) == nil)
	}
}

// MARK: - Config

struct VerboseConfigTests {
	private let key = Data(repeating: 7, count: 32).base64EncodedString()

	@Test func unsetIsNobody() throws {
		let config = try ServerConfig.load(from: ["ERGO_VAULT_KEY": key], production: true, logger: Logger(label: "test"))
		#expect(config.verboseAccounts.isEmpty)
	}

	@Test func readsEmailsAndIdsWithSpacesAndEmptyEntries() throws {
		let id = UUID()
		let list = " Ada@Example.com , \(id.uuidString.lowercased()),, "
		let config = try ServerConfig.load(from: ["ERGO_VAULT_KEY": key, "ERGO_VERBOSE_ACCOUNTS": list], production: true, logger: Logger(label: "test"))

		#expect(config.verboseAccounts == ["ada@example.com", id.uuidString])
	}

	@Test func anEntryThatIsNeitherRefusesToStartWithoutQuotingIt() {
		do {
			_ = try ServerConfig.load(from: ["ERGO_VAULT_KEY": key, "ERGO_VERBOSE_ACCOUNTS": "ada@example.com, typo.canary"], production: true, logger: Logger(label: "test"))
			Issue.record("Expected an entry that is neither to refuse to start")
		} catch let problem as ServerConfig.Problem {
			#expect(problem.description.hasPrefix("ERGO_VERBOSE_ACCOUNTS:"))
			#expect(!problem.description.contains("typo"))
			#expect(!problem.description.contains("ada@example.com"))
		} catch {
			Issue.record("Expected a ServerConfig.Problem, found \(error)")
		}
	}

	@Test func startupSaysHowManyButNeverWho() throws {
		let logs = CapturedLogs()
		_ = try ServerConfig.load(from: ["ERGO_VAULT_KEY": key, "ERGO_VERBOSE_ACCOUNTS": "ada.canary@example.com"], production: true, logger: logs.logger)

		let said = logs.all.joined(separator: "\n")
		#expect(said.contains("1 configured accounts"))
		#expect(!said.contains("canary"))
	}
}

// MARK: - The request log

struct RequestLogTests {
	@Test func workingAsNormalSaysNothing() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let logs = CapturedLogs()
			app.logger = logs.logger

			let account = try await app.createAccount()
			try await app.testing().test(.GET, ErgoProtocol.Path.connections, headers: .signedIn(account.token)) { response async throws in
				#expect(response.status == .ok)
			}

			#expect(!logs.shown.contains { $0.contains("/v1/") }, "Expected nothing for requests that worked, found \(logs.shown)")
		}
	}

	@Test func aVerboseAccountHasEveryRequestWithItsId() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let logs = CapturedLogs()
			app.logger = logs.logger

			let account = try await app.createAccount()
			app.ergo.verbose.remember(account.id)
			try await app.testing().test(.GET, ErgoProtocol.Path.connections, headers: .signedIn(account.token)) { response async throws in
				#expect(response.status == .ok)
			}

			let line = try #require(logs.shown.first { $0.hasPrefix("info GET /v1/connections 200") })
			#expect(line.contains(account.id.uuidString))
			#expect(line.contains("duration"))
			#expect(!logs.shown.joined().contains(account.token))
		}
	}

	@Test func aDeadTokenIsOneWarningAMinuteAndNeverTheToken() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let logs = CapturedLogs()
			app.logger = logs.logger

			for _ in 0 ..< 3 {
				try await app.testing().test(.GET, ErgoProtocol.Path.connections, headers: .signedIn("dead-canary-token")) { response async throws in
					#expect(response.status == .unauthorized)
				}
			}

			let warnings = logs.shown.filter { $0.hasPrefix("warning GET /v1/connections 401") }
			#expect(warnings.count == 1, "Expected one warning for three dead tokens, found \(logs.shown)")
			#expect(warnings.first?.contains("unauthorized") == true)
			#expect(!logs.shown.joined().contains("dead-canary-token"))
		}
	}

	@Test func aFailureIsTheRouteAndAPseudonymForAnAccountThatIsntVerbose() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let logs = CapturedLogs()
			app.logger = logs.logger

			// An anonymous account may not sync
			let account = try await app.createAccount()
			let (status, error) = try await app.syncRefusal(SyncRequest(cursor: nil, changes: []), token: account.token)
			#expect(status == .forbidden)
			#expect(error.code == .signInRequired)

			let line = try #require(logs.shown.first { $0.hasPrefix("warning POST /v1/sync 403") })
			#expect(line.contains(VerboseAccounts.pseudonym(for: account.id)))
			#expect(line.contains("signInRequired"))
			#expect(!logs.shown.joined().contains(account.id.uuidString))
			#expect(!logs.shown.joined().contains(account.token))
		}
	}

	@Test func anUnknownPathIsNeverLoggedAsWritten() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let logs = CapturedLogs()
			app.logger = logs.logger

			try await app.testing().test(.GET, "secret-canary-path", headers: .version) { response async throws in
				#expect(response.status == .badRequest)
			}

			let line = try #require(logs.shown.first { $0.hasPrefix("warning GET /:value 400") })
			#expect(!line.contains("canary"))
		}
	}

	@Test func aToolsClientTold405IsNotAFailure() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let logs = CapturedLogs()
			app.logger = logs.logger

			// A CLI asks for server messages and to end its session on every run
			try await app.testing().test(.GET, "/\(ErgoProtocol.Path.askTools)/tool-canary-token") { response async throws in
				#expect(response.status == .methodNotAllowed)
			}
			try await app.testing().test(.DELETE, "/\(ErgoProtocol.Path.askTools)/tool-canary-token") { response async throws in
				#expect(response.status == .methodNotAllowed)
			}

			#expect(!logs.shown.contains { $0.contains("ask/tools") || $0.contains("canary") }, "Expected nothing for a tools client's routine refusals, found \(logs.shown)")
		}
	}

	@Test func anOutdatedAppIsAWarningWithNoAccount() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let logs = CapturedLogs()
			app.logger = logs.logger

			try await app.testing().test(.POST, ErgoProtocol.Path.accounts) { response async throws in
				#expect(response.status == .upgradeRequired)
			}

			let line = try #require(logs.shown.first { $0.hasPrefix("warning POST /v1/accounts 426") })
			#expect(line.contains("outdatedApp"))
		}
	}
}

// MARK: - Scrubbing

struct ScrubbingTests {
	@Test func aCLIsStderrLosesTheCredentialAndAnythingShapedLikeOne() {
		let secret = Secret("secret-canary-value")
		let text = """
		Error: bad credential secret-canary-value
		key sk-ant-api03-abcdefghijklmnop was refused
		token eyJhbGciOiJFUzI1NiJ9.payload.signature
		plain words stay
		"""

		let scrubbed = ProviderBackend.scrubbed(text, of: secret)
		#expect(!scrubbed.contains("secret-canary-value"))
		#expect(!scrubbed.contains("sk-ant-api03"))
		#expect(!scrubbed.contains("eyJhbGci"))
		#expect(scrubbed.contains("plain words stay"))
	}
}
