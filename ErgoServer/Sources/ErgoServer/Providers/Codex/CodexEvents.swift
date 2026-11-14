//
//  CodexEvents.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import Foundation

/// What `codex exec --json` printed, one event per line. The answer itself comes from `-o`,
/// so this is only read for why a call failed and how many tokens it took.
struct CodexEvents {
	struct Usage: Decodable, Hashable {
		let inputTokens: Int?
		let cachedInputTokens: Int?
		let outputTokens: Int?

		enum CodingKeys: String, CodingKey {
			case inputTokens = "input_tokens"
			case cachedInputTokens = "cached_input_tokens"
			case outputTokens = "output_tokens"
		}
	}

	private struct Event: Decodable {
		struct Message: Decodable {
			let message: String?
		}

		struct Item: Decodable {
			let type: String?
			let text: String?
		}

		let type: String
		let message: String?
		let error: Message?
		let item: Item?
		let usage: Usage?
	}

	/// `turn.failed`'s message, or the last `error` when the turn never finished
	private(set) var failureMessage: String?
	private(set) var usage: Usage?

	/// The last agent message, in case `-o` didn't get written
	private(set) var lastMessage: String?
	private(set) var completed = false

	init(_ output: Data) {
		var lastError: String?
		var turnFailure: String?

		for line in output.split(separator: UInt8(ascii: "\n")) {
			guard let event = try? JSONDecoder().decode(Event.self, from: line) else { continue }
			switch event.type {
				case "turn.completed":
					completed = true
					usage = event.usage
				case "turn.failed":
					turnFailure = event.error?.message
				case "error":
					lastError = event.message
				case "item.completed" where event.item?.type == "agent_message":
					lastMessage = event.item?.text
				default:
					break
			}
		}

		failureMessage = turnFailure ?? (completed ? nil : lastError)
	}

	var failure: ProviderFailure? {
		failureMessage.map(Self.failure)
	}

	/// By wording, since Codex only reports a message
	static func failure(for message: String) -> ProviderFailure {
		let message = cleaned(message)
		let lowercased = message.lowercased()

		if ["401", "unauthorized", "expired", "invalid_api_key", "incorrect api key", "refresh token", "sign in again", "log in again"]
			.contains(where: lowercased.contains)
		{
			return .credentialRejected("ChatGPT rejected the login: \(message)")
		}
		if ["usage limit", "rate limit", "429", "quota", "too many requests"].contains(where: lowercased.contains) {
			return .usageLimit("Reached ChatGPT's usage limit: \(message)")
		}
		return .unavailable("Couldn't reach ChatGPT: \(message)")
	}

	/// Drops the request URL, Cloudflare ray and request id Codex appends, which mean nothing to the user
	static func cleaned(_ message: String) -> String {
		let message = message.range(of: ", url: ").map { String(message[..<$0.lowerBound]) } ?? message
		return message.withoutFullStop
	}
}
