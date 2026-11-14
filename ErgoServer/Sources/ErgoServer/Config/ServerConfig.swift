//
//  ServerConfig.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import Crypto
import ErgoProtocol
import FluentPostgresDriver
import Foundation
import Logging

/// Everything the environment can change, read once at launch
struct ServerConfig: Sendable {
	var databasePath = "./ergo.sqlite"

	/// The Postgres database to use. Nil uses the SQLite file at `databasePath`.
	var postgres: SQLPostgresConfiguration?

	/// Seals credentials at rest
	var vaultKey: SymmetricKey

	/// Where each CLI call gets its own scratch directory
	var runsDirectory = FileManager.default.temporaryDirectory.appending(path: "ergo-runs", directoryHint: .isDirectory)

	var claudePath: String?
	var codexPath: String?

	struct OpenRouter: Sendable {
		/// The server's own key, which pays for every OpenRouter call
		var key: Secret
		var model: String

		/// What paying accounts get. Nil gives everyone `model`.
		var plusModel: String?
	}

	/// How much of the server's own model an account may use. See `UsageService`.
	struct Usage: Sendable {
		/// A day's allowance in millionths of a dollar, at `price`
		var freeDailyMicros = 30000
		var plusDailyMicros = 1_000_000

		/// What every call is counted at, whatever the model really costs, so a free model still uses the allowance up
		var price = UsagePrice(input: 0.2, output: 1.2)
		var freeDeepPerWeek = 1
		var plusDeepPerWeek = 30

		/// Off until the App Store products exist, so nothing is held back for being on the free plan
		var enforcesPlans = false
	}

	var usage = Usage()

	struct DeviceCheck: Sendable {
		/// PEM, a key from the developer portal with DeviceCheck turned on
		var key: String
		var keyID: String
		var teamID: String
	}

	/// Nil gives every account a free allowance, with nothing to stop someone making more accounts
	var deviceCheck: DeviceCheck?

	/// Apple Root CA G3 in PEM, which App Store purchases are checked against. Nil refuses every purchase.
	var appleRootCertificate: String?

	/// Whether a deep research run on the server's own model may search the web, which OpenRouter charges for by the search
	var webSearch = false

	/// Nil when the server has no OpenRouter key, which leaves that provider out
	var openRouter: OpenRouter?

	struct CLIInstall: Sendable {
		var directory: URL
		var npmPath: String
		var claudeCodeVersion: String
		var codexVersion: String
	}

	/// Where a CLI that doesn't run gets installed at launch, and at which version. Nil never installs.
	var cliInstall: CLIInstall?

	/// Put before every CLI, so the CLIs can run as a user that can't read the database or the key
	var runnerPrefix: [String] = []

	/// Who owns a run directory while a CLI runs in it, when the prefix switches to another user
	var runnerUser: String?

	var maxProcesses = 8
	var stageTimeout: Duration = .seconds(120)
	var models = StageModels.defaults

	/// The audience Sign in with Apple tokens must have: the app's bundle id
	var appleApplicationID = "com.adonis.Ergo"

	/// Whether `X-Forwarded-For` says who is asking, for the per-address limits. Only for a server behind a proxy
	/// on the same machine or private network, since otherwise anyone could write it.
	var trustProxy = false

	/// What invite links are built on, with no trailing slash
	var publicURL = "https://ergo-15.235.184.129.sslip.io"

	/// Who the app may be signed by, for the file that makes invite links open it. The app target's team, not the project's.
	var appleTeamIDs = ["P6PV2R9443"]

	struct APNS: Sendable {
		/// PEM. The file Apple gives you, a `.p8`, is already that.
		var key: String
		var keyID: String
		var teamID: String
		var topic: String
	}

	/// Nil sends no pushes
	var apns: APNS?

	struct AppleSignIn: Sendable {
		/// PEM, a key from the developer portal with Sign in with Apple turned on
		var key: String
		var keyID: String
		var teamID: String
	}

	/// Nil never trades a sign-in's code with Apple, so deleting an account can't revoke it
	var appleSignIn: AppleSignIn?

	/// For the join page's App Store link, none until the app is on the store
	var appStoreID: String?

	/// Which apps are answered, and which of those are told to update
	var protocols = ProtocolVersions()

	/// Emails and account ids (`ERGO_VERBOSE_ACCOUNTS`) whose activity is logged in full. Everyone else's is only ever a
	/// pseudonymised warning or error. Never logged itself. See `VerboseAccounts`.
	var verboseAccounts: [String] = []

	// MARK: - Fixed, but shortened by tests

	var requestWait: Duration = .seconds(10)
	var pingInterval: Duration = .seconds(20)
	var deviceLoginTimeout: Duration = .seconds(15 * 60)
	var accountsPerHour = 5
	var registrationsPerHour = 10

	/// Generous, since every user's notifications come from Apple's few addresses
	var appleNotificationsPerMinute = 120

	/// Someone opening a few links is a few of these. Tokens can't be guessed, so this only slows a script.
	var invitePreviewsPerMinute = 30

	/// Reports of shared boards per account
	var reportsPerHour = 10

	/// Failed logins per address, and per email, within `loginWindow`
	var failedLoginsPerWindow = 10
	var loginWindow: TimeInterval = 15 * 60

	/// bcrypt's cost, 2^cost rounds. Tests lower it to the minimum, which still checks passwords.
	var passwordCost = 12
	var syncsPerMinute = SyncLimit.requestsPerMinute
	var recordsPerAccount = SyncLimit.recordsPerAccount

	/// How often tombstones are pruned, first at launch. Nil never prunes, so tests prune by hand.
	var pruneInterval: Duration? = .seconds(24 * 60 * 60)

	init(vaultKey: SymmetricKey) {
		self.vaultKey = vaultKey
	}

	// MARK: - Environment

	struct Problem: Error, CustomStringConvertible {
		let description: String
	}

	/// Production refuses to start without a vault key. Development makes one up, so its credentials only last until a restart.
	static func load(from environment: [String: String], production: Bool, logger: Logger) throws -> ServerConfig {
		var config = try ServerConfig(vaultKey: vaultKey(from: environment, production: production, logger: logger))

		if let path = environment["ERGO_DATABASE_PATH"] {
			config.databasePath = path
		}
		if let url = environment["ERGO_DATABASE_URL"], !url.isEmpty {
			// The driver's own error quotes the URL, which holds the password, and this one gets logged
			guard let postgres = try? SQLPostgresConfiguration(url: url) else {
				throw Problem(description: "ERGO_DATABASE_URL: Expected postgres://user:password@host:port/database")
			}
			config.postgres = postgres
		}
		if let path = environment["ERGO_RUNS_DIRECTORY"] {
			config.runsDirectory = URL(filePath: path, directoryHint: .isDirectory)
		}

		let searchPath = environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
		config.claudePath = environment["ERGO_CLAUDE_PATH"] ?? executable(named: "claude", in: searchPath)
		config.codexPath = environment["ERGO_CODEX_PATH"] ?? executable(named: "codex", in: searchPath)

		if let directory = environment["ERGO_CLI_DIRECTORY"], !directory.isEmpty {
			guard let npm = executable(named: "npm", in: searchPath) else {
				throw Problem(description: "ERGO_CLI_DIRECTORY: Expected npm on PATH to install the CLIs, found none")
			}
			guard let claudeCode = environment["ERGO_CLAUDE_CODE_VERSION"], let codex = environment["ERGO_CODEX_VERSION"] else {
				throw Problem(description: "ERGO_CLI_DIRECTORY: Expected ERGO_CLAUDE_CODE_VERSION and ERGO_CODEX_VERSION to go with it")
			}
			config.cliInstall = CLIInstall(
				directory: URL(filePath: directory, directoryHint: .isDirectory),
				npmPath: npm,
				claudeCodeVersion: claudeCode,
				codexVersion: codex
			)
		}

		if let prefix = environment["ERGO_RUNNER_PREFIX"] {
			config.runnerPrefix = prefix.split(whereSeparator: \.isWhitespace).map(String.init)
		}
		config.runnerUser = environment["ERGO_RUNNER_USER"].flatMap { $0.isEmpty ? nil : $0 }

		if let value = environment["ERGO_MAX_PROCESSES"] {
			guard let count = Int(value), count > 0 else {
				throw Problem(description: "ERGO_MAX_PROCESSES: Expected a positive whole number, found '\(value)'")
			}
			config.maxProcesses = count
		}
		if let value = environment["ERGO_STAGE_TIMEOUT"] {
			guard let seconds = Int(value), seconds > 0 else {
				throw Problem(description: "ERGO_STAGE_TIMEOUT: Expected a positive number of seconds, found '\(value)'")
			}
			config.stageTimeout = .seconds(seconds)
		}
		if let path = environment["ERGO_MODELS_FILE"] {
			config.models = try StageModels.load(from: URL(filePath: path))
		}
		config.models = config.models.overriding(
			claudeModel: environment["ERGO_CLAUDE_MODEL"].flatMap { $0.isEmpty ? nil : $0 },
			codexModel: environment["ERGO_CODEX_MODEL"].flatMap { $0.isEmpty ? nil : $0 },
			effort: environment["ERGO_MODEL_EFFORT"].flatMap { $0.isEmpty ? nil : $0 }
		)
		if let id = environment["ERGO_APPLE_APP_ID"] {
			guard !id.trimmingCharacters(in: .whitespaces).isEmpty else {
				throw Problem(description: "ERGO_APPLE_APP_ID: Expected the app's bundle id, found nothing")
			}
			config.appleApplicationID = id
		}

		if let value = environment["ERGO_TRUST_PROXY"] {
			switch value.lowercased() {
				case "1", "true":
					config.trustProxy = true
				case "0", "false", "":
					config.trustProxy = false
				default:
					throw Problem(description: "ERGO_TRUST_PROXY: Expected 1, true, 0 or false, found '\(value)'")
			}
		}

		try loadOpenRouter(from: environment, into: &config)
		try loadUsage(from: environment, into: &config)
		try loadSharing(from: environment, into: &config)
		try loadAppleSignIn(from: environment, into: &config)
		try loadProtocols(from: environment, into: &config)
		try loadVerboseAccounts(from: environment, into: &config)

		if config.claudePath == nil {
			logger.warning("Couldn't find 'claude' on PATH, Claude connections will fail until ERGO_CLAUDE_PATH is set")
		}
		if config.codexPath == nil {
			logger.warning("Couldn't find 'codex' on PATH, ChatGPT connections will fail until ERGO_CODEX_PATH is set")
		}
		logUnset(in: environment, logger: logger)
		if !config.verboseAccounts.isEmpty {
			// How many, never who
			logger.notice("Logging everything for \(config.verboseAccounts.count) configured accounts")
		}

		return config
	}

	/// Variables that leave something off when none of their names is set, and what that is
	private static let featureVariables: [(names: [String], without: String)] = [
		(["ERGO_DATABASE_URL"], "the database is SQLite"),
		(["ERGO_OPENROUTER_API_KEY"], "the server's own model isn't offered"),
		(["ERGO_APNS_KEY", "ERGO_APNS_KEY_FILE"], "no pushes will be sent"),
		(["ERGO_DEVICECHECK_KEY", "ERGO_DEVICECHECK_KEY_FILE"], "every account gets its own free allowance"),
		(["ERGO_APPLE_SIGNIN_KEY", "ERGO_APPLE_SIGNIN_KEY_FILE"], "Apple sign-ins won't be revoked when an account is deleted"),
		(["ERGO_APPLE_ROOT_CERT_FILE"], "App Store purchases will be refused"),
		(["ERGO_APP_STORE_ID"], "the join page has no App Store link"),
		(["ERGO_VERBOSE_ACCOUNTS"], "only problems are logged, for every account"),
	]

	/// Variables with a default that works. One that's required, or required with another, refuses to start instead.
	private static let defaultedVariables = [
		"ERGO_DATABASE_PATH", "ERGO_RUNS_DIRECTORY", "ERGO_CLI_DIRECTORY", "ERGO_RUNNER_PREFIX", "ERGO_RUNNER_USER",
		"ERGO_MAX_PROCESSES", "ERGO_STAGE_TIMEOUT", "ERGO_MODELS_FILE", "ERGO_CLAUDE_MODEL", "ERGO_CODEX_MODEL",
		"ERGO_MODEL_EFFORT", "ERGO_APPLE_APP_ID", "ERGO_TRUST_PROXY", "ERGO_OPENROUTER_PLUS_MODEL",
		"ERGO_FREE_DAILY_USD", "ERGO_PLUS_DAILY_USD", "ERGO_USAGE_PRICE_INPUT", "ERGO_USAGE_PRICE_OUTPUT",
		"ERGO_FREE_DEEP_PER_WEEK", "ERGO_PLUS_DEEP_PER_WEEK", "ERGO_ENFORCE_PLANS", "ERGO_WEB_SEARCH",
		"ERGO_DEVICECHECK_TEAM_ID", "ERGO_APPLE_SIGNIN_TEAM_ID", "ERGO_PUBLIC_URL", "ERGO_APPLE_TEAM_IDS", "ERGO_APNS_TEAM_ID", "ERGO_APNS_TOPIC",
		"ERGO_MINIMUM_PROTOCOL", "ERGO_RECOMMENDED_PROTOCOL",
	]

	/// Says which variables have no value, by name only. An empty one counts as unset, as it does everywhere above.
	private static func logUnset(in environment: [String: String], logger: Logger) {
		func isSet(_ name: String) -> Bool {
			environment[name]?.isEmpty == false
		}

		for variable in featureVariables where !variable.names.contains(where: isSet) {
			logger.notice("\(variable.names.joined(separator: " or ")) isn't set, so \(variable.without)")
		}
		let defaulted = defaultedVariables.filter { !isSet($0) }
		if !defaulted.isEmpty {
			logger.notice("Using the default for \(defaulted.joined(separator: ", "))")
		}
	}

	private static func loadOpenRouter(from environment: [String: String], into config: inout ServerConfig) throws {
		let key = environment["ERGO_OPENROUTER_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
		let model = environment["ERGO_OPENROUTER_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines)

		guard let key, !key.isEmpty else {
			return
		}
		guard let model, !model.isEmpty else {
			throw Problem(description: "ERGO_OPENROUTER_MODEL: Expected a model id like 'anthropic/claude-sonnet-4.5' to go with ERGO_OPENROUTER_API_KEY")
		}
		let plusModel = environment["ERGO_OPENROUTER_PLUS_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
		config.openRouter = OpenRouter(key: Secret(key), model: model, plusModel: plusModel.flatMap { $0.isEmpty ? nil : $0 })
	}

	private static func flag(_ name: String, in environment: [String: String]) throws -> Bool? {
		guard let value = environment[name] else { return nil }
		switch value.lowercased() {
			case "1", "true":
				return true
			case "0", "false", "":
				return false
			default:
				throw Problem(description: "\(name): Expected 1, true, 0 or false, found '\(value)'")
		}
	}

	/// The allowances on the server's own model, and what checks purchases and devices
	private static func loadUsage(from environment: [String: String], into config: inout ServerConfig) throws {
		func dollars(_ name: String) throws -> Double? {
			guard let value = environment[name], !value.isEmpty else { return nil }
			guard let amount = Double(value), amount >= 0 else {
				throw Problem(description: "\(name): Expected an amount in dollars like 0.03, found '\(value)'")
			}
			return amount
		}
		func count(_ name: String) throws -> Int? {
			guard let value = environment[name], !value.isEmpty else { return nil }
			guard let count = Int(value), count >= 0 else {
				throw Problem(description: "\(name): Expected a whole number, found '\(value)'")
			}
			return count
		}

		if let amount = try dollars("ERGO_FREE_DAILY_USD") {
			config.usage.freeDailyMicros = Int(amount * 1_000_000)
		}
		if let amount = try dollars("ERGO_PLUS_DAILY_USD") {
			config.usage.plusDailyMicros = Int(amount * 1_000_000)
		}
		config.usage.price = try UsagePrice(
			input: dollars("ERGO_USAGE_PRICE_INPUT") ?? config.usage.price.input,
			output: dollars("ERGO_USAGE_PRICE_OUTPUT") ?? config.usage.price.output
		)
		config.usage.freeDeepPerWeek = try count("ERGO_FREE_DEEP_PER_WEEK") ?? config.usage.freeDeepPerWeek
		config.usage.plusDeepPerWeek = try count("ERGO_PLUS_DEEP_PER_WEEK") ?? config.usage.plusDeepPerWeek
		config.usage.enforcesPlans = try flag("ERGO_ENFORCE_PLANS", in: environment) ?? false
		config.webSearch = try flag("ERGO_WEB_SEARCH", in: environment) ?? false

		if let file = environment["ERGO_APPLE_ROOT_CERT_FILE"], !file.isEmpty {
			guard let pem = try? String(contentsOf: URL(filePath: file), encoding: .utf8), pem.contains("BEGIN CERTIFICATE") else {
				throw Problem(description: "ERGO_APPLE_ROOT_CERT_FILE: Expected Apple Root CA G3 in PEM at '\(file)'")
			}
			config.appleRootCertificate = pem
		}
		if config.usage.enforcesPlans, config.appleRootCertificate == nil {
			throw Problem(description: "ERGO_ENFORCE_PLANS: Expected ERGO_APPLE_ROOT_CERT_FILE to go with it, or nobody could pay")
		}

		var pem = environment["ERGO_DEVICECHECK_KEY"].flatMap { $0.isEmpty ? nil : $0 }
		if pem == nil, let file = environment["ERGO_DEVICECHECK_KEY_FILE"], !file.isEmpty {
			do {
				pem = try String(contentsOf: URL(filePath: file), encoding: .utf8)
			} catch {
				throw Problem(description: "ERGO_DEVICECHECK_KEY_FILE: Couldn't read '\(file)'")
			}
		}
		guard let pem else { return }

		// Environment files often can't hold a newline. The error never quotes the key.
		let key = pem.replacingOccurrences(of: "\\n", with: "\n")
		guard (try? P256.Signing.PrivateKey(pemRepresentation: key)) != nil else {
			throw Problem(description: "ERGO_DEVICECHECK_KEY: Expected a P-256 private key in PEM, the .p8 file Apple gives you")
		}
		guard let keyID = environment["ERGO_DEVICECHECK_KEY_ID"], !keyID.isEmpty else {
			throw Problem(description: "ERGO_DEVICECHECK_KEY_ID: Expected the key's id to go with ERGO_DEVICECHECK_KEY")
		}
		config.deviceCheck = DeviceCheck(
			key: key,
			keyID: keyID,
			teamID: environment["ERGO_DEVICECHECK_TEAM_ID"].flatMap { $0.isEmpty ? nil : $0 } ?? "P6PV2R9443"
		)
	}

	private static func loadProtocols(from environment: [String: String], into config: inout ServerConfig) throws {
		func version(_ name: String, from lowest: Int) throws -> Int? {
			guard let value = environment[name], !value.isEmpty else { return nil }
			guard let version = Int(value), lowest ... config.protocols.current ~= version else {
				throw Problem(description: "\(name): Expected a protocol from \(lowest) to \(config.protocols.current), found '\(value)'")
			}
			return version
		}

		config.protocols.minimum = try version("ERGO_MINIMUM_PROTOCOL", from: ErgoProtocol.minimumVersion) ?? config.protocols.minimum
		config.protocols.recommended = try version("ERGO_RECOMMENDED_PROTOCOL", from: config.protocols.minimum) ?? config.protocols.minimum
	}

	/// Emails or account ids separated by commas. An entry that is neither refuses to start, without saying what it was,
	/// since the list is Adon's own accounts and never goes in a log.
	private static func loadVerboseAccounts(from environment: [String: String], into config: inout ServerConfig) throws {
		guard let list = environment["ERGO_VERBOSE_ACCOUNTS"], !list.isEmpty else { return }

		for entry in list.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !entry.isEmpty {
			if let id = UUID(uuidString: entry) {
				config.verboseAccounts.append(id.uuidString)
			} else if let email = try? AccountEmail.normalized(entry) {
				config.verboseAccounts.append(email)
			} else {
				throw Problem(description: "ERGO_VERBOSE_ACCOUNTS: Expected emails or account ids separated by commas, found an entry that is neither")
			}
		}
	}

	/// After `ERGO_APPLE_APP_ID`, which is the default APNs topic
	private static func loadSharing(from environment: [String: String], into config: inout ServerConfig) throws {
		if let url = environment["ERGO_PUBLIC_URL"], !url.isEmpty {
			var trimmed = url
			while trimmed.hasSuffix("/") {
				trimmed.removeLast()
			}
			guard trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://"), URL(string: trimmed) != nil else {
				throw Problem(description: "ERGO_PUBLIC_URL: Expected an http or https URL, found '\(url)'")
			}
			config.publicURL = trimmed
		}
		if let teams = environment["ERGO_APPLE_TEAM_IDS"], !teams.isEmpty {
			let ids = teams.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
			guard !ids.isEmpty else {
				throw Problem(description: "ERGO_APPLE_TEAM_IDS: Expected team ids separated by commas, found none")
			}
			config.appleTeamIDs = ids
		}
		config.appStoreID = environment["ERGO_APP_STORE_ID"].flatMap { $0.isEmpty ? nil : $0 }

		var pem = environment["ERGO_APNS_KEY"].flatMap { $0.isEmpty ? nil : $0 }
		if pem == nil, let file = environment["ERGO_APNS_KEY_FILE"], !file.isEmpty {
			do {
				pem = try String(contentsOf: URL(filePath: file), encoding: .utf8)
			} catch {
				throw Problem(description: "ERGO_APNS_KEY_FILE: Couldn't read '\(file)'")
			}
		}
		guard let pem else { return }

		// Environment files often can't hold a newline. The error never quotes the key.
		let key = pem.replacingOccurrences(of: "\\n", with: "\n")
		guard (try? P256.Signing.PrivateKey(pemRepresentation: key)) != nil else {
			throw Problem(description: "ERGO_APNS_KEY: Expected a P-256 private key in PEM, the .p8 file Apple gives you")
		}
		guard let keyID = environment["ERGO_APNS_KEY_ID"], !keyID.isEmpty else {
			throw Problem(description: "ERGO_APNS_KEY_ID: Expected the key's id to go with ERGO_APNS_KEY")
		}
		config.apns = APNS(
			key: key,
			keyID: keyID,
			teamID: environment["ERGO_APNS_TEAM_ID"].flatMap { $0.isEmpty ? nil : $0 } ?? "P6PV2R9443",
			topic: environment["ERGO_APNS_TOPIC"].flatMap { $0.isEmpty ? nil : $0 } ?? config.appleApplicationID
		)
	}

	/// After `ERGO_APPLE_APP_ID`, which is the client id
	private static func loadAppleSignIn(from environment: [String: String], into config: inout ServerConfig) throws {
		var pem = environment["ERGO_APPLE_SIGNIN_KEY"].flatMap { $0.isEmpty ? nil : $0 }
		if pem == nil, let file = environment["ERGO_APPLE_SIGNIN_KEY_FILE"], !file.isEmpty {
			do {
				pem = try String(contentsOf: URL(filePath: file), encoding: .utf8)
			} catch {
				throw Problem(description: "ERGO_APPLE_SIGNIN_KEY_FILE: Couldn't read '\(file)'")
			}
		}
		guard let pem else { return }

		// Environment files often can't hold a newline. The error never quotes the key.
		let key = pem.replacingOccurrences(of: "\\n", with: "\n")
		guard (try? P256.Signing.PrivateKey(pemRepresentation: key)) != nil else {
			throw Problem(description: "ERGO_APPLE_SIGNIN_KEY: Expected a P-256 private key in PEM, the .p8 file Apple gives you")
		}
		guard let keyID = environment["ERGO_APPLE_SIGNIN_KEY_ID"], !keyID.isEmpty else {
			throw Problem(description: "ERGO_APPLE_SIGNIN_KEY_ID: Expected the key's id to go with ERGO_APPLE_SIGNIN_KEY")
		}
		config.appleSignIn = AppleSignIn(
			key: key,
			keyID: keyID,
			teamID: environment["ERGO_APPLE_SIGNIN_TEAM_ID"].flatMap { $0.isEmpty ? nil : $0 } ?? "P6PV2R9443"
		)
	}

	private static func vaultKey(from environment: [String: String], production: Bool, logger: Logger) throws -> SymmetricKey {
		var encoded = environment["ERGO_VAULT_KEY"]
		if encoded == nil, let file = environment["ERGO_VAULT_KEY_FILE"] {
			do {
				encoded = try String(contentsOf: URL(filePath: file), encoding: .utf8)
			} catch {
				throw Problem(description: "ERGO_VAULT_KEY_FILE: Couldn't read '\(file)'")
			}
		}

		guard let encoded else {
			guard !production else {
				throw Problem(description: "Expected ERGO_VAULT_KEY or ERGO_VAULT_KEY_FILE, 32 bytes of base64")
			}
			logger.warning("No ERGO_VAULT_KEY, using a random one, so stored credentials won't survive a restart")
			return SymmetricKey(size: .bits256)
		}

		guard let data = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)), data.count == 32 else {
			throw Problem(description: "ERGO_VAULT_KEY: Expected 32 bytes of base64")
		}
		return SymmetricKey(data: data)
	}

	private static func executable(named name: String, in searchPath: String) -> String? {
		searchPath
			.split(separator: ":")
			.map { "\($0)/\(name)" }
			.first { FileManager.default.isExecutableFile(atPath: $0) }
	}
}
