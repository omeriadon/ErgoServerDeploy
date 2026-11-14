//
//  ProviderBackend.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoProtocol
import ErgoTranslation
import Foundation
import Logging

/// Answers each stage by running the provider's CLI with the user's own credential, in a fresh directory every call
struct ProviderBackend: TranslationBackend {
	let credential: ProviderCredential
	let models: StageModels
	let runner: ProcessRunner
	let config: ServerConfig
	let logger: Logger

	/// Codex refreshed its tokens during a call, so this `auth.json` replaces the stored one
	let refreshed: @Sendable (Secret) async -> Void

	/// The secret as the last call left it
	let latest: LatestSecret

	/// Counts what the server's own model uses, and says which model the account's plan gets. Nil for anyone's own login.
	let meter: UsageMeter?

	init(
		credential: ProviderCredential,
		config: ServerConfig,
		runner: ProcessRunner,
		logger: Logger,
		meter: UsageMeter? = nil,
		refreshed: @escaping @Sendable (Secret) async -> Void = { _ in }
	) {
		self.meter = meter
		self.credential = credential
		models = config.models
		self.runner = runner
		self.config = config
		self.logger = logger
		self.refreshed = refreshed
		latest = LatestSecret(credential.secret)
	}

	var policy: TranslationPolicy {
		models.policy
	}

	/// The pipeline only retries compile and verify problems, so an answer that doesn't fit the schema gets one more try here
	func run<Stage: TranslationStage>(_ stage: Stage.Type, _ input: Stage.Input) async throws -> Stage.Output {
		let prompt = try StagePrompts.message(for: input)

		for attempt in 1 ... 2 {
			if let output = try await call(stage, prompt: prompt) {
				return output
			}
			logger.warning("Answer didn't match the schema", metadata: ["stage": "\(Stage.name)", "provider": "\(credential.provider)", "attempt": "\(attempt)"])
		}
		throw ProviderFailure.unavailable("\(credential.provider.displayName) didn't answer in the expected format")
	}

	private func call<Stage: TranslationStage>(_ stage: Stage.Type, prompt: String) async throws -> Stage.Output? {
		try await RunDirectory.with(in: config.runsDirectory) { run in
			switch credential.provider {
				case .claude:
					try await claude(stage, prompt: prompt, in: run)
				case .codex:
					try await codex(stage, prompt: prompt, in: run)
				case .openrouter:
					try await openRouter(stage, prompt: prompt)
			}
		}
	}

	// MARK: - Claude Code

	private func claude<Stage: TranslationStage>(_: Stage.Type, prompt: String, in run: RunDirectory) async throws -> Stage.Output? {
		guard let executable = config.claudePath else {
			throw ProviderFailure.unavailable("Claude Code isn't installed on the Ergo server")
		}

		let instructions = run.work.appending(path: "instructions.md")
		try run.write(StagePrompts.instructions(for: Stage.name), to: instructions)

		let command = ClaudeCodeCommand(
			executable: executable,
			choice: models.choice(for: .claude, stage: Stage.name),
			schema: Stage.outputSchema.encoded(),
			instructions: instructions,
			credential: credential,
			run: run
		)
		let finished = try await launch(command.command(prompt: prompt), in: run, stage: Stage.name)

		guard let result = ClaudeCodeResult.decode(finished.output) else {
			log(Stage.name, finished, problem: "no result JSON")
			throw ProviderFailure.unavailable("Claude Code failed on the Ergo server")
		}
		log(Stage.name, finished, usage: [
			"input_tokens": result.usage?.inputTokens,
			"output_tokens": result.usage?.outputTokens,
			"cache_read_tokens": result.usage?.cacheReadInputTokens,
			"cache_write_tokens": result.usage?.cacheCreationInputTokens,
		])
		return try result.output(Stage.Output.self, from: finished.output, kind: credential.kind)
	}

	// MARK: - Codex

	private func codex<Stage: TranslationStage>(_: Stage.Type, prompt: String, in run: RunDirectory) async throws -> Stage.Output? {
		guard let executable = config.codexPath else {
			throw ProviderFailure.unavailable("Codex isn't installed on the Ergo server")
		}

		let secret = latest.current
		let command = try CodexCommand(
			executable: executable,
			choice: models.choice(for: .codex, stage: Stage.name),
			instructions: StagePrompts.instructions(for: Stage.name),
			credential: ProviderCredential(provider: credential.provider, kind: credential.kind, secret: secret),
			run: run
		)
		try run.write(Stage.outputSchema.encoded(), to: command.schemaFile)
		if credential.kind == .subscription {
			try run.write(secret.value, to: command.authFile)
		}

		// Read back however the call ends, since Codex may have rotated the refresh token even if it then failed
		let outcome = await Result(catching: { try await launch(command.command(prompt: prompt), in: run, stage: Stage.name) })
		if credential.kind == .subscription {
			await saveRefreshedAuth(from: command.authFile, replacing: secret, in: run)
		}
		let finished = try outcome.get()

		let events = CodexEvents(finished.output)
		log(Stage.name, finished, usage: [
			"input_tokens": events.usage?.inputTokens,
			"cached_input_tokens": events.usage?.cachedInputTokens,
			"output_tokens": events.usage?.outputTokens,
		])
		if let failure = events.failure {
			throw failure
		}

		guard let answer = run.read(command.answerFile) ?? events.lastMessage else {
			log(Stage.name, finished, problem: "no answer")
			throw ProviderFailure.unavailable("Codex failed on the Ergo server")
		}
		return try? JSONDecoder().decode(Stage.Output.self, from: Data(answer.utf8))
	}

	func saveRefreshedAuth(from file: URL, replacing secret: Secret, in run: RunDirectory) async {
		guard let contents = run.read(file), contents != secret.value, CodexAuthFile.problem(with: contents) == nil else {
			return
		}
		logger.verbose("Codex refreshed its login", metadata: ["provider": "\(credential.provider)"])
		latest.replace(with: Secret(contents))
		await refreshed(Secret(contents))
	}

	// MARK: - Running

	private func launch(_ command: ProcessRunner.Command, in run: RunDirectory, stage: String) async throws -> ProcessRunner.Finished {
		do {
			return try await runner.run(command, in: run)
		} catch is ProcessRunner.TimedOut {
			logger.warning("CLI timed out", metadata: ["stage": "\(stage)", "provider": "\(credential.provider)"])
			throw ProviderFailure.timedOut("Expected an answer from \(credential.provider.displayName) within \(runner.timeout.spelledOut)")
		} catch let error as CancellationError {
			throw error
		} catch {
			logger.error("Couldn't run the CLI", metadata: ["stage": "\(stage)", "provider": "\(credential.provider)", "error": "\(error)"])
			throw ProviderFailure.unavailable("Couldn't run \(credential.provider.cliName) on the Ergo server")
		}
	}

	/// Never the output itself, it can echo the prompt or a secret. The stderr tail only goes out when something's wrong,
	/// and only for a verbose account, since it can quote what was asked or the credential. Even then it's scrubbed.
	private func log(_ stage: String, _ finished: ProcessRunner.Finished, usage: [String: Int?] = [:], problem: String? = nil) {
		var metadata: Logger.Metadata = [
			"stage": "\(stage)",
			"provider": "\(credential.provider)",
			"duration": "\(finished.duration)",
			"exit": "\(finished.status)",
		]
		for case let (key, value?) in usage {
			metadata[key] = "\(value)"
		}

		if let problem {
			metadata["problem"] = "\(problem)"
			if logger.isVerbose {
				metadata["stderr"] = "\(Self.scrubbed(String(finished.errorOutput.suffix(1000)), of: credential.secret))"
			}
			logger.error("CLI call failed", metadata: metadata)
		} else {
			logger.verbose("CLI call", metadata: metadata)
		}
	}

	/// Without the credential, or anything shaped like a key or a token, which a CLI sometimes prints back
	static func scrubbed(_ text: String, of secret: Secret) -> String {
		var scrubbed = text
		if !secret.value.isEmpty {
			scrubbed = scrubbed.replacingOccurrences(of: secret.value, with: "<redacted>")
		}
		return scrubbed.replacing(/(?:sk-|eyJ)[A-Za-z0-9_.\-]{12,}/, with: "<redacted>")
	}
}

private extension Result where Failure == any Error {
	init(catching body: () async throws -> Success) async {
		do {
			self = try await .success(body())
		} catch {
			self = .failure(error)
		}
	}
}
