//
//  ConnectionVerifier.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoTranslation
import Foundation
import Logging

/// Proves a credential works with one cheap call before it's stored. A closure, so tests can stand in for the CLI.
struct ConnectionVerifier: Sendable {
	/// Throws a `ProviderFailure` when the call fails. Returns the secret to store, which Codex may have refreshed on the way.
	let verify: @Sendable (ProviderCredential, Logger) async throws -> Secret

	func callAsFunction(_ credential: ProviderCredential, logger: Logger) async throws -> Secret {
		try await verify(credential, logger)
	}

	/// One gate call, with the gate's models, on a sentence that's plainly an argument
	static func live(config: ServerConfig, runner: ProcessRunner) -> ConnectionVerifier {
		ConnectionVerifier { credential, logger in
			let backend = ProviderBackend(credential: credential, config: config, runner: runner, logger: logger)
			_ = try await backend.run(GateStage.self, GateStage.Input(english: "It's raining, so the ground is wet."))
			return backend.latest.current
		}
	}
}
