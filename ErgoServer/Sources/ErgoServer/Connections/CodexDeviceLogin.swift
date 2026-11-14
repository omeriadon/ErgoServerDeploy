//
//  CodexDeviceLogin.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoProtocol
import Foundation
import Subprocess
import Synchronization
import Vapor

/// `WS v1/connections/codex/device-login`: runs `codex login --device-auth` in a fresh directory, passes its code on,
/// and stores the `auth.json` it writes once a call with it works. Closing the socket stops the process.
struct CodexDeviceLogin {
	let request: Request
	let socket: WebSocket

	static let arguments = ["login", "--device-auth"] + CodexCommand.settings([("cli_auth_credentials_store", "file")])

	func run() async {
		socket.logClosing("Codex login", logger: request.logger)
		let work = Task { () -> DeviceLoginMessage in
			do {
				return try await .connected(login(account: request.accountID))
			} catch let failure as ProviderFailure {
				request.logger.warning("Device login refused", metadata: ["code": "\(failure.serviceError.code)"])
				return .failed(failure.serviceError)
			} catch let error as ServiceError {
				return .failed(error)
			} catch {
				if !(error is CancellationError) {
					request.logger.error("Device login failed", metadata: ["error": "\(request.logger.reason(for: error))"])
				}
				return .failed(.internalFailure)
			}
		}
		socket.onClose.whenComplete { _ in
			work.cancel()
		}

		let outcome = await work.value
		guard !socket.isClosed else { return }
		await send(outcome)
		try? await socket.close(code: .normalClosure)
	}

	private func login(account: UUID) async throws -> ConnectionStatus {
		let services = request.ergo
		guard let executable = services.config.codexPath else {
			throw ProviderFailure.unavailable("Codex isn't installed on the Ergo server")
		}

		let auth = try await RunDirectory.with(in: services.config.runsDirectory) { run in
			let codexHome = run.home.appending(path: ".codex", directoryHint: .isDirectory)
			try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

			let command = ProcessRunner.Command(
				executable: executable,
				arguments: Self.arguments,
				environment: CodexCommand.environment(home: run.home, codexHome: codexHome, executable: executable),
				directory: run.work
			)

			let scanner = DeviceCodeScanner()
			let status: TerminationStatus
			do {
				status = try await services.runner.stream(command, in: run, timeout: services.config.deviceLoginTimeout) { line in
					if let (url, code) = scanner.scan(line) {
						await send(.code(url: url, code: code))
					}
				}
			} catch is ProcessRunner.TimedOut {
				request.logger.warning("Codex login timed out", metadata: ["limit": "\(services.config.deviceLoginTimeout.spelledOut)"])
				throw ServiceError(code: .timedOut, message: "Expected the ChatGPT login to finish within \(services.config.deviceLoginTimeout.spelledOut)")
			}

			guard status == .exited(0) else {
				request.logger.warning("Codex login failed", metadata: ["exit": "\(status)"])
				throw ProviderFailure.unavailable(scanner.failure)
			}
			guard let auth = run.read(codexHome.appending(path: CodexAuthFile.name)) else {
				throw ProviderFailure.unavailable("Expected Codex to save the ChatGPT login, found nothing")
			}
			return auth
		}

		if let problem = CodexAuthFile.problem(with: auth) {
			throw ProviderFailure.unavailable(problem)
		}
		let status = try await ConnectionController.store(
			ProviderCredential(provider: .codex, kind: .subscription, secret: Secret(auth)),
			account: account,
			on: request
		)
		request.logger.verbose("Codex login finished")
		return status
	}

	private func send(_ message: DeviceLoginMessage) async {
		guard let data = try? ErgoProtocol.encoder.encode(message) else { return }
		try? await socket.send(String(decoding: data, as: UTF8.self))
	}
}

// MARK: - DeviceCodeScanner

/// Picks the verification URL and the one-time code out of what `codex login --device-auth` prints, which is meant for a terminal
final class DeviceCodeScanner: Sendable {
	private struct State {
		var url: URL?
		var sent = false
		var lines: [String] = []
	}

	private let state = Mutex(State())

	/// The URL and code, once both have turned up, and only the first time
	func scan(_ line: String) -> (URL, String)? {
		let line = Self.plain(line)

		return state.withLock { state in
			state.lines = Array((state.lines + [line]).suffix(20))
			guard !state.sent else { return nil }

			if state.url == nil, let match = line.firstMatch(of: /https:\/\/[^\s'"<>]+/) {
				state.url = URL(string: String(match.output))
				return nil
			}
			// Like 'ABCD-EFGH1', but any blocks of capitals and digits joined by dashes
			guard let url = state.url, let match = line.firstMatch(of: /\b[A-Z0-9]{4,}(?:-[A-Z0-9]{4,})+\b/) else {
				return nil
			}
			state.sent = true
			return (url, String(match.output))
		}
	}

	/// Why the login failed, from the last thing Codex said
	var failure: String {
		let lines = state.withLock(\.lines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
		let output = lines.joined(separator: "\n").lowercased()

		if output.contains("device code"), output.contains("enable") || output.contains("disabled") || output.contains("not allowed") {
			return "Expected device code login to be on, turn it on in ChatGPT's security settings"
		}
		guard let last = lines.last?.trimmingCharacters(in: .whitespaces) else {
			return "Couldn't log in to ChatGPT"
		}
		return "Couldn't log in to ChatGPT: \(last.withoutFullStop)"
	}

	/// Without terminal colours
	static func plain(_ line: String) -> String {
		line.replacing(/\x{1B}\[[0-9;?]*[ -\/]*[@-~]/, with: "")
	}
}
