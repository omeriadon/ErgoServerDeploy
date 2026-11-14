//
//  OpenRouterStream.swift
//  ErgoServer
//
//  Created by Adon Omeri on 9/11/2026.
//

import ErgoProtocol
import Foundation

/// Reads OpenRouter's server-sent events a line at a time and builds the completion they add up to. Comment lines
/// (`: OPENROUTER PROCESSING`), blank lines and `[DONE]` say nothing.
struct OpenRouterStream {
	private struct Chunk: Decodable {
		struct Choice: Decodable {
			struct Delta: Decodable {
				struct Call: Decodable {
					struct Function: Decodable {
						let name: String?
						let arguments: String?
					}

					let index: Int?
					let id: String?
					let function: Function?
				}

				let content: String?
				let toolCalls: [Call]?

				enum CodingKeys: String, CodingKey {
					case content
					case toolCalls = "tool_calls"
				}
			}

			let delta: Delta?
			let finishReason: String?

			enum CodingKeys: String, CodingKey {
				case delta
				case finishReason = "finish_reason"
			}
		}

		struct Failure: Decodable {
			let message: String?
		}

		let choices: [Choice]?
		let usage: OpenRouterClient.Usage?
		let error: Failure?
	}

	private(set) var completion = OpenRouterClient.Completion()

	/// Tool calls arrive in pieces, keyed by their index
	private var calls: [Int: OpenRouterClient.ToolCall] = [:]

	/// The answer's next piece, if the line had one. Throws when OpenRouter says the stream failed partway.
	mutating func feed(_ line: [UInt8]) throws(ProviderFailure) -> String? {
		let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
		guard text.hasPrefix("data:") else { return nil }

		let payload = text.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
		guard payload != "[DONE]", let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(payload.utf8)) else { return nil }

		if chunk.error != nil {
			throw .unavailable("\(Provider.openrouter.displayName) stopped partway through its answer")
		}
		if let usage = chunk.usage {
			completion.usage = usage
		}
		guard let choice = chunk.choices?.first else { return nil }

		if let reason = choice.finishReason {
			completion.finishReason = reason
		}
		for call in choice.delta?.toolCalls ?? [] {
			let index = call.index ?? 0
			var known = calls[index] ?? OpenRouterClient.ToolCall(id: "call_\(index)", name: "", arguments: "")
			if let id = call.id, !id.isEmpty {
				known.id = id
			}
			if let name = call.function?.name {
				known.name += name
			}
			if let arguments = call.function?.arguments {
				known.arguments += arguments
			}
			calls[index] = known
			completion.toolCalls = calls.sorted { $0.key < $1.key }.map(\.value)
		}

		guard let content = choice.delta?.content, !content.isEmpty else { return nil }
		completion.text += content
		return content
	}
}
