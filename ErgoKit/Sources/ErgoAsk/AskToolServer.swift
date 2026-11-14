//
//  AskToolServer.swift
//  ErgoKit
//
//  Created by Adon Omeri on 6/11/2026.
//

import ErgoProtocol
import ErgoSync
import Foundation

/// The little of MCP the CLIs need to reach a run's tools, over plain JSON-RPC: one message in, at most one out.
/// Both Claude Code and Codex speak this to a URL, so tool calls reach the server the same way for either.
public struct AskToolServer<Tools: AskToolSet>: Sendable {
	static var fallbackVersion: String {
		"2025-06-18"
	}

	public let tools: Tools

	public init(tools: Tools) {
		self.tools = tools
	}

	private struct Message: Decodable {
		let id: JSONValue?
		let method: String?
		let params: JSONValue?
	}

	/// Empty when there's nothing to say back, which is the answer to a notification. `events` hears what the app should
	/// know as tools run.
	public func respond(to body: Data, events: @Sendable (Tools.Event) async -> Void) async -> Data {
		guard let message = try? JSONDecoder().decode(Message.self, from: body) else {
			return Self.failure(id: .null, code: -32700, "Expected a JSON-RPC message")
		}
		guard let id = message.id, let method = message.method else {
			return Data()
		}

		let params: [String: JSONValue] = if case let .object(object)? = message.params {
			object
		} else {
			[:]
		}

		switch method {
			case "initialize":
				var version = Self.fallbackVersion
				if case let .string(requested)? = params["protocolVersion"] {
					version = requested
				}
				return Self.result(id: id, .object([
					"protocolVersion": .string(version),
					"capabilities": .object(["tools": .object([:])]),
					"serverInfo": .object(["name": .string("ergo"), "version": .string("1")]),
				]))

			case "ping":
				return Self.result(id: id, .object([:]))

			case "tools/list":
				return Self.result(id: id, .object(["tools": .array(tools.definitions)]))

			case "tools/call":
				guard case let .string(name)? = params["name"] else {
					return Self.failure(id: id, code: -32602, "Expected a tool name")
				}
				var arguments: [String: JSONValue] = [:]
				if case let .object(object)? = params["arguments"] {
					arguments = object
				}
				return await call(name, arguments: arguments, id: id, events: events)

			default:
				return Self.failure(id: id, code: -32601, "No method is called '\(method)'")
		}
	}

	private func call(_ name: String, arguments: [String: JSONValue], id: JSONValue, events: @Sendable (Tools.Event) async -> Void) async -> Data {
		if let running = tools.event(running: name, arguments: arguments) {
			await events(running)
		}

		do {
			let reply = try tools.reply(to: name, arguments: arguments)
			if let event = reply.event {
				await events(event)
			}
			return Self.toolResult(id: id, reply.text, isError: false)
		} catch {
			// Reported as a result, not a protocol error, so the model reads it and can put it right
			return Self.toolResult(id: id, error.message, isError: true)
		}
	}

	private static func toolResult(id: JSONValue, _ text: String, isError: Bool) -> Data {
		result(id: id, .object([
			"content": .array([.object(["type": .string("text"), "text": .string(text)])]),
			"isError": .bool(isError),
		]))
	}

	private static func result(id: JSONValue, _ result: JSONValue) -> Data {
		encoded(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
	}

	private static func failure(id: JSONValue, code: Int, _ message: String) -> Data {
		encoded(.object([
			"jsonrpc": .string("2.0"),
			"id": id,
			"error": .object(["code": .number(Double(code)), "message": .string(message)]),
		]))
	}

	private static func encoded(_ value: JSONValue) -> Data {
		(try? JSONEncoder().encode(value)) ?? Data()
	}
}
