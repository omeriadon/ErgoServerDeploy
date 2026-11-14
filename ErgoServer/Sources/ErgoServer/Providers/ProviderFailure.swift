//
//  ProviderFailure.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoProtocol
import Foundation

/// Why a CLI call didn't produce an answer, already worded for the user
enum ProviderFailure: Error, Hashable {
	case credentialRejected(String)
	case usageLimit(String)
	case unavailable(String)
	case timedOut(String)

	var serviceError: ServiceError {
		switch self {
			case let .credentialRejected(message):
				ServiceError(code: .credentialRejected, message: message)
			case let .usageLimit(message):
				ServiceError(code: .usageLimit, message: message)
			case let .unavailable(message):
				ServiceError(code: .providerUnavailable, message: message)
			case let .timedOut(message):
				ServiceError(code: .timedOut, message: message)
		}
	}
}

extension Provider {
	/// What the user knows it as. The server's own model is Ergo's, so its vendor never shows.
	var displayName: String {
		switch self {
			case .claude: "Claude"
			case .codex: "ChatGPT"
			case .openrouter: "Ergo's model"
		}
	}

	/// The CLI that runs it, for messages about the server
	var cliName: String {
		switch self {
			case .claude: "Claude Code"
			case .codex: "Codex"
			case .openrouter: "Ergo's model"
		}
	}
}

extension String {
	/// Messages from the CLIs read like sentences, but the app's errors don't end in a full stop
	var withoutFullStop: String {
		var text = trimmingCharacters(in: .whitespacesAndNewlines)
		while text.hasSuffix(".") {
			text.removeLast()
		}
		return text
	}
}

extension Duration {
	/// "1 second", "2 minutes", for messages
	var spelledOut: String {
		let seconds = components.seconds
		let (count, unit) = seconds >= 60 && seconds % 60 == 0 ? (seconds / 60, "minute") : (seconds, "second")
		return "\(count) \(unit)\(count == 1 ? "" : "s")"
	}
}
