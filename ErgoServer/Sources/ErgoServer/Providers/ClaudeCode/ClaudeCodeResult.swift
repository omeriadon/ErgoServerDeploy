//
//  ClaudeCodeResult.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoProtocol
import Foundation

/// The JSON `claude -p --output-format json` prints once it's done, cut down to what the server reads
struct ClaudeCodeResult: Decodable {
	struct Usage: Decodable {
		let inputTokens: Int?
		let outputTokens: Int?
		let cacheReadInputTokens: Int?
		let cacheCreationInputTokens: Int?

		enum CodingKeys: String, CodingKey {
			case inputTokens = "input_tokens"
			case outputTokens = "output_tokens"
			case cacheReadInputTokens = "cache_read_input_tokens"
			case cacheCreationInputTokens = "cache_creation_input_tokens"
		}
	}

	let isError: Bool
	let apiErrorStatus: Int?

	/// The answer as text, or the error message when `isError`
	let result: String?
	let usage: Usage?
	let totalCost: Double?

	enum CodingKeys: String, CodingKey {
		case isError = "is_error"
		case apiErrorStatus = "api_error_status"
		case result
		case usage
		case totalCost = "total_cost_usd"
	}

	private struct Structured<Output: Decodable>: Decodable {
		let output: Output

		enum CodingKeys: String, CodingKey {
			case output = "structured_output"
		}
	}

	static func decode(_ data: Data) -> ClaudeCodeResult? {
		try? JSONDecoder().decode(ClaudeCodeResult.self, from: data)
	}

	/// The answer, or nil when it doesn't match the schema. Throws when Claude refused the call.
	func output<Output: Decodable>(_: Output.Type, from data: Data, kind: CredentialKind) throws(ProviderFailure) -> Output? {
		if let failure = failure(kind: kind) {
			throw failure
		}
		return (try? JSONDecoder().decode(Structured<Output>.self, from: data))?.output
	}

	func failure(kind: CredentialKind) -> ProviderFailure? {
		guard isError else { return nil }
		let message = (result ?? "").withoutFullStop
		let lowercased = message.lowercased()

		if apiErrorStatus == 401 || apiErrorStatus == 403 {
			let what = kind == .subscription ? "token" : "API key"
			return .credentialRejected("Claude rejected the \(what): \(message)")
		}
		if apiErrorStatus == 429 || ["usage limit", "rate limit", "limit reached", "hit your limit"].contains(where: lowercased.contains) {
			return .usageLimit("Reached Claude's usage limit: \(message)")
		}
		return .unavailable(message.isEmpty ? "Claude couldn't answer" : "Claude couldn't answer: \(message)")
	}
}
