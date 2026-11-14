//
//  TranslationService.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoLogic
import ErgoProtocol
import ErgoTranslation
import Fluent
import Foundation
import Logging
import Synchronization

/// Runs translations, one at a time per account. Codex spends its refresh token as it uses it, so two calls
/// with one login at once could leave the stored copy already spent. Connection checks go through here too.
final class TranslationService: Sendable {
	let vault: CredentialVault
	let config: ServerConfig
	let runner: ProcessRunner
	let usage: UsageService
	private let running = Mutex<Set<UUID>>([])

	init(vault: CredentialVault, config: ServerConfig, runner: ProcessRunner, usage: UsageService? = nil) {
		self.vault = vault
		self.config = config
		self.runner = runner
		self.usage = usage ?? UsageService(config: config)
	}

	// MARK: - Single flight

	/// Throws `.busy` straight away when the account already has something running
	func exclusive<T>(for account: UUID, _ body: () async throws -> T) async throws -> T {
		guard running.withLock({ $0.insert(account).inserted }) else {
			throw ServiceError(code: .busy, message: "Expected one translation at a time, another one is still running")
		}
		defer { running.withLock { _ = $0.remove(account) } }
		return try await body()
	}

	// MARK: - Translating

	/// Throws a `ServiceError`, or `CancellationError` once the CLI's been stopped. English that isn't worth a model call
	/// comes back as a translation with that issue, the same as the pipeline would give.
	func translate(
		_ request: TranslateRequest,
		account: UUID,
		database: any Database,
		logger: Logger,
		events: @escaping @Sendable (TranslationEvent) async -> Void
	) async throws -> Translation {
		try check(request, logger: logger)
		if let problem = EnglishValidator.problem(with: request.english) {
			return Translation(english: request.english, issues: [TranslationIssue(severity: .error, message: problem)])
		}

		return try await withBackend(provider: request.provider, scope: request.scope.rawValue, account: account, database: database, logger: logger) { backend in
			try await pipeline(for: request, backend: backend).translate(request.english, events: events)
		} summary: { translation in
			["issues": "\(translation.issues.count)"]
		}
	}

	/// The same checks and rules as `translate`, for a pasted argument: only the gate and breakdown run
	func breakDown(
		_ request: TranslateRequest,
		account: UUID,
		database: any Database,
		logger: Logger,
		events: @escaping @Sendable (TranslationEvent) async -> Void
	) async throws -> ArgumentBreakdown {
		try check(request, logger: logger)
		if let problem = EnglishValidator.problem(with: request.english) {
			return ArgumentBreakdown(
				kind: .neither,
				descriptors: LogicLetters.slots.map { LogicLetters.descriptor(for: $0, in: request.descriptors ?? []) },
				issues: [TranslationIssue(severity: .error, message: problem)]
			)
		}

		return try await withBackend(provider: request.provider, scope: request.scope.rawValue, account: account, database: database, logger: logger) { backend in
			try await pipeline(for: request, backend: backend).breakDown(request.english, events: events)
		} summary: { breakdown in
			["premises": "\(breakdown.premises.count)", "issues": "\(breakdown.issues.count)"]
		}
	}

	private func pipeline(for request: TranslateRequest, backend: ProviderBackend) -> TranslationPipeline {
		TranslationPipeline(backend: backend, letters: request.letters, descriptors: request.descriptors)
	}

	/// Says so in the log when it refuses, since a socket has no status to
	private func check(_ request: TranslateRequest, logger: Logger) throws {
		do {
			try check(request)
		} catch let refusal as ServiceError {
			logger.warning("A request was refused", metadata: ["scope": "\(request.scope.rawValue)", "code": "\(refusal.code)"])
			throw refusal
		}
	}

	/// What no model call is needed to refuse: another grammar, letters or descriptors the app would never send
	private func check(_ request: TranslateRequest) throws {
		guard request.grammarVersion == LogicGrammar.version else {
			throw ServiceError(code: .outdatedApp, message: "Expected logic grammar \(LogicGrammar.version), found \(request.grammarVersion), update the app")
		}
		guard LogicLetters.resolved(request.letters) == request.letters else {
			throw ServiceError(code: .invalidRequest, message: "Expected six distinct letters, found '\(request.letters.joined(separator: " "))'")
		}
		if let descriptors = request.descriptors {
			guard descriptors.count <= LogicLetters.slots.count else {
				throw ServiceError(code: .invalidRequest, message: "Expected at most \(LogicLetters.slots.count) descriptors, found \(descriptors.count)")
			}
			if let long = descriptors.first(where: { $0.count > LogicLetters.descriptorLengthLimit }) {
				throw ServiceError(
					code: .invalidRequest,
					message: "Expected descriptors of at most \(LogicLetters.descriptorLengthLimit) characters, found \(long.count)"
				)
			}
		}
	}

	/// Opens the user's connection, runs `work` with it, one at a time per account, and turns whatever goes wrong into
	/// a `ServiceError`. `summary` is what's worth logging about the result, never its text. `exclusive` is false for a
	/// Claude Code login, which has nothing to spend, when the call shouldn't make everything else wait.
	///
	/// The server's own model is refused once the account's allowance for today is used, and what the call uses is counted
	/// against it. `counts` is false for a deep research run, which is counted by the week instead. A run that finds the
	/// account busy says so in the log, unless `warnsWhenBusy` is false for a caller that will try again.
	func withBackend<Result: Sendable>(
		provider: Provider,
		scope: String,
		account: UUID,
		database: any Database,
		logger: Logger,
		exclusive isExclusive: Bool = true,
		counts: Bool = true,
		warnsWhenBusy: Bool = true,
		_ work: (ProviderBackend) async throws -> Result,
		summary: (Result) -> Logger.Metadata
	) async throws -> Result {
		// A server-managed provider uses the server's own key, so there's no row to find, mark or reseal
		let id: UUID?
		let credential: ProviderCredential
		let meter: UsageMeter?
		do {
			if provider.isServerManaged {
				guard let openRouter = config.openRouter else {
					throw ServiceError(code: .notConnected, message: "\(provider.displayName) isn't set up on the Ergo server")
				}
				id = nil
				credential = ProviderCredential(provider: provider, kind: .apiKey, secret: openRouter.key)
				let plan: AccountPlan = if counts {
					try await usage.requireAllowance(for: account, on: database)
				} else {
					try await usage.plan(of: account, on: database).plan
				}
				meter = UsageMeter(model: plan == .plus ? openRouter.plusModel : nil)
				logger.verbose("Allowance checked", metadata: ["plan": "\(plan)", "counted": "\(counts)"])
			} else {
				meter = nil
				guard let stored = try await Credential.find(provider, for: account, on: database), let storedID = stored.id else {
					throw ServiceError(code: .notConnected, message: "\(provider.displayName) isn't connected")
				}
				id = storedID
				do {
					credential = try ProviderCredential(
						provider: stored.provider,
						kind: stored.kind,
						secret: vault.open(stored.sealed, account: account, provider: stored.provider)
					)
				} catch {
					logger.error("Couldn't unseal a credential", metadata: ["provider": "\(provider)"])
					throw ServiceError(code: .notConnected, message: "Couldn't read the saved \(provider.displayName) connection, connect it again")
				}
			}
		} catch let refusal as ServiceError {
			// Nothing has run, and what asked (a socket, a detached run) has no status of its own to say so
			logger.warning("A run was refused", metadata: ["provider": "\(provider)", "scope": "\(scope)", "code": "\(refusal.code)"])
			throw refusal
		} catch let cancelled as CancellationError {
			throw cancelled
		} catch {
			// The database, most likely, which a detached run would otherwise report to the app without a word here
			logger.error("A run couldn't be set up", metadata: ["provider": "\(provider)", "scope": "\(scope)", "error": "\(logger.reason(for: error))"])
			throw error
		}

		// A connection's status is for the app's Settings, so not saving it fails nothing, but it should be known
		func note(_ what: String, _ update: () async throws -> Void) async {
			do {
				try await update()
			} catch {
				logger.warning("Couldn't save a connection's status", metadata: ["status": "\(what)", "error": "\(String(describing: type(of: error)))"])
			}
		}

		func run() async throws -> Result {
			logger.verbose("Run started", metadata: ["provider": "\(credential.provider)", "scope": "\(scope)"])
			let backend = ProviderBackend(credential: credential, config: config, runner: runner, logger: logger, meter: meter) { [vault] refreshed in
				guard let id else { return }
				do {
					try await Credential.reseal(id, with: vault.seal(refreshed, account: account, provider: credential.provider), on: database)
				} catch {
					logger.error("Couldn't save a refreshed login", metadata: ["provider": "\(credential.provider)"])
				}
			}

			// Whatever the call used counts, however it ended
			func settle() async {
				if counts, let meter {
					await usage.record(meter, for: account, on: database, logger: logger)
				}
			}

			let start = ContinuousClock.now
			do {
				let result: Result
				do {
					result = try await work(backend)
				} catch {
					await settle()
					throw error
				}
				await settle()
				if let id {
					await note("working") { try await Credential.markWorking(id, on: database) }
				}
				var metadata: Logger.Metadata = [
					"provider": "\(credential.provider)",
					"scope": "\(scope)",
					"duration": "\(start.duration(to: .now))",
				]
				metadata.merge(summary(result)) { first, _ in first }
				logger.verbose("Translated", metadata: metadata)
				return result
			} catch let failure as ProviderFailure {
				if let id, case let .credentialRejected(problem) = failure {
					await note("rejected") { try await Credential.mark(id, problem: problem, on: database) }
				}
				logger.warning("Translation failed", metadata: ["provider": "\(credential.provider)", "code": "\(failure.serviceError.code)", "duration": "\(start.duration(to: .now))"])
				throw failure.serviceError
			} catch let error as CancellationError {
				logger.verbose("Translation cancelled", metadata: ["provider": "\(credential.provider)", "duration": "\(start.duration(to: .now))"])
				throw error
			} catch {
				logger.error("Translation failed", metadata: ["provider": "\(credential.provider)", "error": "\(logger.reason(for: error))"])
				throw ServiceError.internalFailure
			}
		}

		guard isExclusive else {
			return try await run()
		}
		do {
			return try await exclusive(for: account, run)
		} catch let busy as ServiceError where busy.code == .busy && warnsWhenBusy {
			// Only `exclusive` says busy, before anything ran
			logger.warning("A run was refused", metadata: ["provider": "\(provider)", "scope": "\(scope)", "code": "\(busy.code)"])
			throw busy
		}
	}
}
