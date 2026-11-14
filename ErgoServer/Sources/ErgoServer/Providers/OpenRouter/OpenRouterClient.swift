//
//  OpenRouterClient.swift
//  ErgoServer
//
//  Created by Adon Omeri on 9/11/2026.
//

import AsyncHTTPClient
import ErgoProtocol
import Foundation
import Logging
import Vapor

/// One streamed chat completion from OpenRouter, made with the server's own key. There's no CLI in between, so this is the
/// whole of what the other providers need a process for.
struct OpenRouterClient: Sendable {
	static let endpoint = "https://openrouter.ai/api/v1/chat/completions"

	struct ToolCall: Sendable, Hashable {
		var id: String
		var name: String
		var arguments: String
	}

	struct Usage: Decodable, Sendable, Hashable {
		let promptTokens: Int?
		let completionTokens: Int?

		enum CodingKeys: String, CodingKey {
			case promptTokens = "prompt_tokens"
			case completionTokens = "completion_tokens"
		}
	}

	struct Completion: Sendable {
		var text = ""
		var toolCalls: [ToolCall] = []
		var finishReason: String?
		var usage: Usage?
	}

	let key: Secret
	let logger: Logger

	/// `body` is the request's JSON. `text` hears each piece of the answer as it arrives, and `timeout` is for the whole call.
	/// Throws a `ProviderFailure`, or `CancellationError` once the call's been stopped.
	func complete(_ body: Data, timeout: Duration, text: @Sendable (String) async -> Void) async throws -> Completion {
		var request = HTTPClientRequest(url: Self.endpoint)
		request.method = .POST
		request.headers.add(name: "Authorization", value: "Bearer \(key.value)")
		request.headers.add(name: "Content-Type", value: "application/json")
		request.headers.add(name: "X-Title", value: "Ergo")
		request.body = .bytes(ByteBuffer(bytes: body))

		do {
			let response = try await AsyncHTTPClient.HTTPClient.shared.execute(request, timeout: .nanoseconds(timeout.wholeNanoseconds))
			guard response.status == .ok else {
				let detail = try? await response.body.collect(upTo: 64 * 1024)
				throw failure(status: Int(response.status.code), body: detail.map { Data($0.readableBytesView) } ?? Data())
			}

			var stream = OpenRouterStream()
			var pending = [UInt8]()
			for try await chunk in response.body {
				pending.append(contentsOf: chunk.readableBytesView)
				while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
					let line = Array(pending[..<newline])
					pending.removeSubrange(...newline)
					if let more = try stream.feed(line) {
						await text(more)
					}
				}
			}
			if !pending.isEmpty, let more = try stream.feed(pending) {
				await text(more)
			}
			return stream.completion
		} catch let error as HTTPClientError where error == .deadlineExceeded || error == .readTimeout {
			throw ProviderFailure.timedOut("Expected an answer from \(Provider.openrouter.displayName) within \(timeout.spelledOut)")
		} catch let error as HTTPClientError where error == .cancelled {
			throw CancellationError()
		} catch let error as ProviderFailure {
			throw error
		} catch let error as CancellationError {
			throw error
		} catch {
			logger.error("Couldn't reach OpenRouter", metadata: ["error": "\(String(describing: type(of: error)))"])
			throw ProviderFailure.unavailable("Couldn't reach \(Provider.openrouter.displayName) from the Ergo server")
		}
	}

	// MARK: - Failures

	/// The server's key is what OpenRouter checks, not the user's, so a refused key is the server's problem
	private func failure(status: Int, body: Data) -> ProviderFailure {
		struct Reply: Decodable {
			struct Detail: Decodable {
				let message: String?
			}

			let error: Detail?
		}

		let message = (try? JSONDecoder().decode(Reply.self, from: body))?.error?.message
		var metadata: Logger.Metadata = ["status": "\(status)"]
		// What OpenRouter says can quote the request, so it's only for a verbose account
		if logger.isVerbose, let message {
			metadata["message"] = "\(String(message.prefix(300)))"
		}
		logger.warning("OpenRouter refused a call", metadata: metadata)

		switch status {
			case 401, 403:
				return .unavailable("\(Provider.openrouter.displayName) isn't available right now")
			case 402:
				return .unavailable("The Ergo server is out of credit")
			case 429:
				return .usageLimit("\(Provider.openrouter.displayName) is busy, try again in a moment")
			case 400:
				return .unavailable("The model couldn't take this request, try again or shorten the text")
			case 404:
				return .unavailable("The model isn't available for this request right now")
			default:
				return .unavailable("\(Provider.openrouter.displayName) failed on its side")
		}
	}
}

private extension Duration {
	var wholeNanoseconds: Int64 {
		let (seconds, attoseconds) = components
		return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
	}
}
