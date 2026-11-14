//
//  Provider.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import Foundation

/// Whose model translates, always through the user's own account
public enum Provider: String, Codable, Sendable, CaseIterable, Hashable {
	case claude, codex

	/// The server's own OpenRouter key and model, so there's nothing for a user to connect
	case openrouter

	/// Whether the server supplies the credential, so it can't be connected or disconnected
	public var isServerManaged: Bool {
		self == .openrouter
	}
}

public enum CredentialKind: String, Codable, Sendable, Hashable {
	/// claude: `claude setup-token` output. codex: the contents of `~/.codex/auth.json`.
	case subscription

	/// claude: an Anthropic API key. codex: an OpenAI API key.
	case apiKey
}
