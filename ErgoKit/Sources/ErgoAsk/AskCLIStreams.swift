//
//  AskCLIStreams.swift
//  ErgoKit
//
//  Created by Adon Omeri on 6/11/2026.
//

import Foundation

/// Reads the answer out of `claude -p --output-format stream-json --include-partial-messages`, a JSON object per line.
/// Lines that aren't JSON, like anything on stderr, are skipped.
public struct ClaudeAskStream: Sendable {
	private struct Line: Decodable {
		struct Event: Decodable {
			struct Delta: Decodable {
				let type: String?
				let text: String?
			}

			struct Block: Decodable {
				let type: String?
			}

			let type: String?
			let delta: Delta?
			let contentBlock: Block?

			enum CodingKeys: String, CodingKey {
				case type, delta
				case contentBlock = "content_block"
			}
		}

		let type: String?
		let event: Event?
		let result: String?
	}

	private var hasText = false
	private var startsNewBlock = false

	/// The last `result` line as it came, which says how the run ended
	public private(set) var resultLine: Data?

	public init() {}

	/// More of the answer, if this line has any
	public mutating func feed(_ line: String) -> String? {
		let data = Data(line.utf8)
		guard let decoded = try? JSONDecoder().decode(Line.self, from: data) else { return nil }

		switch decoded.type {
			case "stream_event":
				switch decoded.event?.type {
					case "content_block_start":
						if decoded.event?.contentBlock?.type == "text" {
							startsNewBlock = true
						}
					case "content_block_delta":
						guard decoded.event?.delta?.type == "text_delta", let text = decoded.event?.delta?.text, !text.isEmpty else { return nil }
						return added(text)
					default:
						break
				}
			case "result":
				resultLine = data
				// Only when nothing streamed, since this repeats the last message
				if !hasText, let result = decoded.result, !result.isEmpty {
					return added(result)
				}
			default:
				break
		}
		return nil
	}

	private mutating func added(_ text: String) -> String {
		// Text before and after a tool call are separate blocks that would otherwise run together
		let separator = hasText && startsNewBlock ? "\n\n" : ""
		hasText = true
		startsNewBlock = false
		return separator + text
	}
}

/// Reads the answer out of `codex exec --json`, which reports each message whole once it's finished
public struct CodexAskStream: Sendable {
	private struct Line: Decodable {
		struct Item: Decodable {
			let type: String?
			let text: String?
		}

		let type: String?
		let item: Item?
	}

	private var hasText = false

	/// Every line, for `CodexEvents` to find out how the run ended
	public private(set) var output = Data()

	public init() {}

	public mutating func feed(_ line: String) -> String? {
		output.append(Data(line.utf8))
		output.append(UInt8(ascii: "\n"))

		guard
			let decoded = try? JSONDecoder().decode(Line.self, from: Data(line.utf8)),
			decoded.type == "item.completed",
			decoded.item?.type == "agent_message",
			let text = decoded.item?.text,
			!text.isEmpty
		else {
			return nil
		}
		defer { hasText = true }
		return hasText ? "\n\n" + text : text
	}
}

/// One conversation with `codex app-server`, a JSON-RPC message per line both ways. Unlike `codex exec`, it reports each
/// token as it's written. It has to be answered as it goes, since starting a turn needs the id the thread comes back with.
public struct CodexAppServerSession: Sendable {
	public enum Output: Sendable, Hashable {
		/// Write this line to its stdin
		case send(String)

		/// More of the answer
		case text(String)

		case finished
		case failed(String)
	}

	private enum Request {
		static let initialize = 1
		static let startThread = 2
		static let startTurn = 3
	}

	private struct Line: Decodable {
		struct Failure: Decodable {
			let message: String?
		}

		struct Params: Decodable {
			struct Turn: Decodable {
				let status: String?
				let error: Failure?
			}

			let delta: String?
			let itemId: String?
			let turn: Turn?
		}

		struct Result: Decodable {
			struct Thread: Decodable {
				let id: String
			}

			let thread: Thread?
		}

		let id: Int?
		let method: String?
		let params: Params?
		let result: Result?
		let error: Failure?
	}

	private let prompt: String
	private let directory: String
	private var currentItem: String?

	public init(prompt: String, directory: String) {
		self.prompt = prompt
		self.directory = directory
	}

	/// What to write first
	public var opening: String {
		Self.line(["id": Request.initialize, "method": "initialize", "params": ["clientInfo": ["name": "ergo", "version": "1"]]])
	}

	public mutating func feed(_ line: String) -> [Output] {
		guard let decoded = try? JSONDecoder().decode(Line.self, from: Data(line.utf8)) else { return [] }

		if let id = decoded.id, decoded.method == nil {
			return reply(to: id, decoded)
		}

		switch decoded.method {
			case "item/agentMessage/delta":
				guard let delta = decoded.params?.delta, !delta.isEmpty else { return [] }
				// A new message after a tool call, which would otherwise run into the last one
				let isNewItem = decoded.params?.itemId != currentItem
				let separator = isNewItem && currentItem != nil ? "\n\n" : ""
				currentItem = decoded.params?.itemId
				return [.text(separator + delta)]

			case "turn/completed":
				guard let turn = decoded.params?.turn, turn.status != "completed" else { return [.finished] }
				return [.failed(turn.error?.message ?? "The turn ended as \(turn.status ?? "unknown")")]

			default:
				// Its `error` notifications are mostly retries it's handling itself. One that gives up ends the turn.
				return []
		}
	}

	private func reply(to id: Int, _ line: Line) -> [Output] {
		if let error = line.error {
			return [.failed(error.message ?? "Codex refused the request")]
		}
		switch id {
			case Request.initialize:
				return [
					.send(Self.line(["method": "initialized"])),
					.send(Self.line(["id": Request.startThread, "method": "thread/start", "params": ["ephemeral": true, "cwd": directory]])),
				]
			case Request.startThread:
				guard let thread = line.result?.thread?.id else {
					return [.failed("Expected a thread from Codex, found none")]
				}
				return [.send(Self.line([
					"id": Request.startTurn,
					"method": "turn/start",
					"params": ["threadId": thread, "input": [["type": "text", "text": prompt]]],
				]))]
			default:
				return []
		}
	}

	private static func line(_ message: [String: Any]) -> String {
		guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return "{}" }
		return String(decoding: data, as: UTF8.self)
	}
}
