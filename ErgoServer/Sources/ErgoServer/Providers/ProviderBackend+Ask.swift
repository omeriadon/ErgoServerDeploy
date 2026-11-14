//
//  ProviderBackend+Ask.swift
//  ErgoServer
//
//  Created by Adon Omeri on 6/11/2026.
//

import ErgoAsk
import ErgoProtocol
import Foundation
import Logging
import Synchronization

/// What differs between the runs that talk to Ergo's tools: Ask's answers, and a board analysis
struct AskRunSettings: Sendable {
	/// The instructions' name in `Resources`. The model is always `StageModels.ask`'s.
	let instructions: String

	/// More instructions added after those, by name: a chat's mode, or that it's about a board
	var additions: [String] = []

	/// What Claude Code may call, without the `mcp__ergo__` prefix
	let toolNames: [String]

	/// A CLI can stop to call tools several times, so it gets longer than one stage's single answer
	let timeout: Duration

	/// How many rounds of tool calls Claude Code may make
	let maxTurns: Int

	/// Whether the server's own model may search the web, when the server allows it at all
	var searchesWeb = false

	static let ask = AskRunSettings(instructions: StageModels.ask, toolNames: AskTools.names, timeout: .seconds(300), maxTurns: ClaudeCodeAskCommand.maxTurns)

	/// A chat in a mode, or about a board, which then has the board's tools
	static func ask(mode: AskMode, board: AskBoard?) -> AskRunSettings {
		var additions: [String] = []
		if board != nil {
			additions.append(StagePrompts.board)
		}
		if mode != .normal {
			additions.append(mode.rawValue)
		}
		return AskRunSettings(
			instructions: StageModels.ask,
			additions: additions,
			toolNames: board.map { BoardChatTools.names(canEdit: $0.canEdit) } ?? AskTools.names,
			timeout: .seconds(300),
			maxTurns: ClaudeCodeAskCommand.maxTurns
		)
	}

	/// A whole board: reading the library, then a report for every card, arrow and source
	static let analysis = AskRunSettings(instructions: StageModels.analyse, toolNames: BoardAnalysisTools.names, timeout: .seconds(600), maxTurns: 400, searchesWeb: true)

	/// Everything the model is told, in order
	func text(webSearch: Bool = false) throws -> String {
		try ([instructions] + additions + (webSearch ? [StagePrompts.web] : []))
			.map { try StagePrompts.instructions(for: $0) }
			.joined(separator: "\n\n")
	}
}

/// One CLI call for Ask: free text as it's written, with Ergo's tools as the only ones it has
extension ProviderBackend {
	/// `tools` is the URL this run's tools answer at, for a CLI, and `responder` is the same tools for a provider with no CLI.
	/// `text` hears more of the answer as it's written.
	func ask(prompt: String, tools: String, responder: @escaping AskRuns.Responder, settings: AskRunSettings = .ask, text: @escaping @Sendable (String) async -> Void) async throws {
		try await RunDirectory.with(in: config.runsDirectory) { run in
			switch credential.provider {
				case .claude:
					try await claudeAsk(prompt: prompt, tools: tools, settings: settings, in: run, text: text)
				case .codex:
					try await codexAsk(prompt: prompt, tools: tools, settings: settings, in: run, text: text)
				case .openrouter:
					try await openRouterAsk(prompt: prompt, settings: settings, responder: responder, text: text)
			}
		}
	}

	// MARK: - Claude Code

	private func claudeAsk(prompt: String, tools: String, settings: AskRunSettings, in run: RunDirectory, text: @escaping @Sendable (String) async -> Void) async throws {
		guard let executable = config.claudePath else {
			throw ProviderFailure.unavailable("Claude Code isn't installed on the Ergo server")
		}

		let instructions = run.work.appending(path: "instructions.md")
		let toolConfig = run.work.appending(path: "tools.json")
		try run.write(settings.text(), to: instructions)
		try run.write(ClaudeCodeAskCommand.toolConfig(url: tools), to: toolConfig)

		let command = ClaudeCodeAskCommand(
			executable: executable,
			choice: models.choice(for: .claude, stage: StageModels.ask),
			instructions: instructions,
			toolConfig: toolConfig,
			credential: credential,
			run: run,
			toolNames: settings.toolNames,
			maxTurns: settings.maxTurns
		)

		let stream = AskStreamBox(ClaudeAskStream())
		try await streamAsk(command.command(prompt: prompt), settings: settings, in: run) { line in
			if let more = stream.withLock({ $0.feed(line) }) {
				await text(more)
			}
		}

		guard let line = stream.withLock({ $0.resultLine }), let result = ClaudeCodeResult.decode(line) else {
			throw ProviderFailure.unavailable("Claude Code failed on the Ergo server")
		}
		if let failure = result.failure(kind: credential.kind) {
			throw failure
		}
	}

	// MARK: - Codex

	private func codexAsk(prompt: String, tools: String, settings: AskRunSettings, in run: RunDirectory, text: @escaping @Sendable (String) async -> Void) async throws {
		guard let executable = config.codexPath else {
			throw ProviderFailure.unavailable("Codex isn't installed on the Ergo server")
		}

		let secret = latest.current
		let command = try CodexCommand(
			executable: executable,
			choice: models.choice(for: .codex, stage: StageModels.ask),
			instructions: settings.text(),
			credential: ProviderCredential(provider: credential.provider, kind: credential.kind, secret: secret),
			run: run,
			tools: tools
		)

		// A login streams tokens through the app server. An API key can only use `exec`, which gives whole messages.
		guard credential.kind == .apiKey else {
			try run.write(secret.value, to: command.authFile)
			return try await codexAppServerAsk(command, prompt: prompt, secret: secret, settings: settings, in: run, text: text)
		}

		let stream = AskStreamBox(CodexAskStream())
		let outcome: Result<Void, any Error>
		do {
			try await streamAsk(command.command(prompt: prompt), settings: settings, in: run) { line in
				if let more = stream.withLock({ $0.feed(line) }) {
					await text(more)
				}
			}
			outcome = .success(())
		} catch {
			outcome = .failure(error)
		}

		try outcome.get()

		let events = CodexEvents(stream.withLock { $0.output })
		if let failure = events.failure {
			throw failure
		}
		guard events.completed else {
			throw ProviderFailure.unavailable("Codex failed on the Ergo server")
		}
	}

	private func codexAppServerAsk(
		_ command: CodexCommand,
		prompt: String,
		secret: Secret,
		settings: AskRunSettings,
		in run: RunDirectory,
		text: @escaping @Sendable (String) async -> Void
	) async throws {
		let start = CodexAppServerSession(prompt: prompt, directory: run.work.path)
		let session = AskStreamBox(start)
		let finished = AskStreamBox(false)
		let failure = AskStreamBox<String?>(nil)

		let outcome: Result<Void, any Error>
		do {
			try await translatingFailures(settings) {
				_ = try await runner.converse(command.appServerCommand, in: run, timeout: settings.timeout, opening: start.opening) { line in
					var reply = ProcessRunner.Reply()
					for output in session.withLock({ $0.feed(line) }) {
						switch output {
							case let .send(message):
								reply.send.append(message)
							case let .text(more):
								await text(more)
							case .finished:
								finished.withLock { $0 = true }
								reply.isDone = true
							case let .failed(message):
								failure.withLock { $0 = message }
								reply.isDone = true
						}
					}
					return reply
				}
			}
			outcome = .success(())
		} catch {
			outcome = .failure(error)
		}

		// Read back however the call ends, since Codex may have rotated the refresh token even if it then failed
		await saveRefreshedAuth(from: command.authFile, replacing: secret, in: run)
		try outcome.get()

		if let message = failure.withLock({ $0 }) {
			throw CodexEvents.failure(for: message)
		}
		guard finished.withLock({ $0 }) else {
			throw ProviderFailure.unavailable("Codex failed on the Ergo server")
		}
	}

	// MARK: - Running

	private func streamAsk(_ command: ProcessRunner.Command, settings: AskRunSettings, in run: RunDirectory, lines: @escaping @Sendable (String) async -> Void) async throws {
		try await translatingFailures(settings) {
			_ = try await runner.stream(command, in: run, timeout: settings.timeout, lines: lines)
		}
	}

	private func translatingFailures(_ settings: AskRunSettings, _ work: () async throws -> Void) async throws {
		do {
			try await work()
		} catch is ProcessRunner.TimedOut {
			logger.warning("CLI timed out", metadata: ["stage": "\(StageModels.ask)", "provider": "\(credential.provider)"])
			throw ProviderFailure.timedOut("Expected an answer from \(credential.provider.displayName) within \(settings.timeout.spelledOut)")
		} catch let error as CancellationError {
			throw error
		} catch let failure as ProviderFailure {
			throw failure
		} catch {
			logger.error("Couldn't run the CLI", metadata: ["stage": "\(StageModels.ask)", "provider": "\(credential.provider)", "error": "\(error)"])
			throw ProviderFailure.unavailable("Couldn't run \(credential.provider.cliName) on the Ergo server")
		}
	}
}

/// Lets a stream parser be fed from the line handler and read once the call's over
private final class AskStreamBox<Stream: Sendable>: Sendable {
	private let stream: Mutex<Stream>

	init(_ stream: Stream) {
		self.stream = Mutex(stream)
	}

	func withLock<Result: Sendable>(_ body: @Sendable (inout Stream) -> Result) -> Result {
		stream.withLock { body(&$0) }
	}
}
