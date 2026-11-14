//
//  ErgoServices.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoAsk
import ErgoCatalog
import ErgoProtocol
import Foundation
import Vapor

/// What every route shares, made once in `configure`
struct ErgoServices: Sendable {
	let config: ServerConfig
	let vault: CredentialVault
	let runner: ProcessRunner
	let accountLimiter: CreateAccountLimiter
	let registerLimiter: CreateAccountLimiter
	let loginLimiter: LoginLimiter
	let appleNotificationLimiter: CreateAccountLimiter
	let appleNotifications: SeenNotifications

	/// Which accounts are logged in full, and the lines that would repeat too often to be said every time
	let verbose: VerboseAccounts
	let logThrottle = LogThrottle()

	/// What an unknown email's password is checked against, so it takes as long as a known one's
	let dummyPasswordHash: String
	let translations: TranslationService
	let usage: UsageService
	let ask: AskService
	let askTools: AskToolServer<AskTools>
	let analyses: BoardAnalysisService

	/// Asks and breakdowns, which carry on when the app that started them is closed. See `DetachedRuns`.
	let detached = DetachedRuns()
	let verifier: ConnectionVerifier
	let apple: AppleTokenVerifier
	let appleTokens: AppleRefreshTokens
	let syncLimits: SyncLimits
	let live: SyncLive
	let sync: SyncService
	let push: PushService
	let sharing: BoardSharing
	let invitePreviewLimiter: CreateAccountLimiter
	let reportLimiter: CreateAccountLimiter

	init(
		config: ServerConfig,
		verifier: ConnectionVerifier? = nil,
		apple: AppleTokenVerifier? = nil,
		appleTokens: AppleRefreshTokens? = nil,
		push sender: PushSender = .disabled
	) throws {
		let runner = ProcessRunner(
			prefix: config.runnerPrefix,
			owner: config.runnerUser.flatMap(ProcessRunner.Owner.init(named:)),
			maxProcesses: config.maxProcesses,
			timeout: config.stageTimeout
		)

		self.config = config
		self.runner = runner
		let verbose = VerboseAccounts(config.verboseAccounts)
		self.verbose = verbose
		let vault = CredentialVault(key: config.vaultKey)
		self.vault = vault
		accountLimiter = CreateAccountLimiter(limit: config.accountsPerHour)
		registerLimiter = CreateAccountLimiter(limit: config.registrationsPerHour)
		loginLimiter = LoginLimiter(limit: config.failedLoginsPerWindow, window: config.loginWindow)
		appleNotificationLimiter = CreateAccountLimiter(limit: config.appleNotificationsPerMinute, window: 60)
		appleNotifications = SeenNotifications()
		dummyPasswordHash = try Bcrypt.hash(UUID().uuidString, cost: config.passwordCost)
		let usage = UsageService(config: config)
		self.usage = usage
		let translations = TranslationService(vault: vault, config: config, runner: runner, usage: usage)
		self.translations = translations
		let catalog = try LibraryCatalog.load()
		let askTools = AskToolServer(tools: AskTools(catalog: catalog))
		self.askTools = askTools
		let ask = AskService(translations: translations, tools: askTools)
		self.ask = ask
		self.verifier = verifier ?? .live(config: config, runner: runner)
		self.apple = apple ?? .live(applicationIdentifier: config.appleApplicationID)
		self.appleTokens = appleTokens ?? .live(config: config)
		syncLimits = SyncLimits(requestsPerMinute: config.syncsPerMinute)
		let live = SyncLive()
		self.live = live
		let push = PushService(sender: sender, live: live, verbose: verbose)
		self.push = push
		let sharing = BoardSharing(vault: vault, live: live, push: push, publicURL: config.publicURL)
		self.sharing = sharing
		invitePreviewLimiter = CreateAccountLimiter(limit: config.invitePreviewsPerMinute, window: 60)
		reportLimiter = CreateAccountLimiter(limit: config.reportsPerHour)
		sync = SyncService(vault: vault, live: live, sharing: sharing, recordsPerAccount: config.recordsPerAccount)
		analyses = BoardAnalysisService(translations: translations, runs: ask.runs, sharing: sharing, catalog: catalog)
	}
}

extension Application {
	private struct ServicesKey: StorageKey {
		typealias Value = ErgoServices
	}

	/// Set by `configure`, before any route can run
	var ergo: ErgoServices {
		get {
			guard let services = storage[ServicesKey.self] else {
				fatalError("Expected configure(_:) to set up ErgoServices before the first request")
			}
			return services
		}
		set {
			storage[ServicesKey.self] = newValue
		}
	}
}

extension Request {
	var ergo: ErgoServices {
		application.ergo
	}
}
