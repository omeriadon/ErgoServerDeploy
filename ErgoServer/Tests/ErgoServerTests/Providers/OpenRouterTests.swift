//
//  OpenRouterTests.swift
//  ErgoServer
//
//  Created by Adon Omeri on 9/11/2026.
//

@testable import ErgoServer
import Foundation
import Testing

struct OpenRouterStreamTests {
	private func feed(_ lines: [String]) throws -> (pieces: [String], stream: OpenRouterStream) {
		var stream = OpenRouterStream()
		var pieces: [String] = []
		for line in lines {
			if let piece = try stream.feed(Array(line.utf8)) {
				pieces.append(piece)
			}
		}
		return (pieces, stream)
	}

	@Test func textArrivesInPieces() throws {
		let result = try feed([
			": OPENROUTER PROCESSING",
			#"data: {"choices":[{"delta":{"content":"Hel"}}]}"#,
			"",
			#"data: {"choices":[{"delta":{"content":"lo"},"finish_reason":"stop"}]}"#,
			#"data: {"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":2}}"#,
			"data: [DONE]",
		])
		#expect(result.pieces == ["Hel", "lo"])
		#expect(result.stream.completion.text == "Hello")
		#expect(result.stream.completion.finishReason == "stop")
		#expect(result.stream.completion.usage?.completionTokens == 2)
	}

	@Test func toolCallsAreJoinedByIndex() throws {
		let result = try feed([
			#"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","function":{"name":"search_library","arguments":""}}]}}]}"#,
			#"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"query\":"}}]}}]}"#,
			#"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"bias\"}"}}]},"finish_reason":"tool_calls"}]}"#,
		])
		#expect(result.pieces.isEmpty)
		#expect(result.stream.completion.toolCalls == [OpenRouterClient.ToolCall(id: "call_a", name: "search_library", arguments: #"{"query":"bias"}"#)])
	}

	@Test func aFailurePartwayThrows() {
		#expect(throws: ProviderFailure.self) {
			_ = try feed([#"data: {"error":{"message":"Provider disconnected"},"choices":[{"finish_reason":"error"}]}"#])
		}
	}
}
