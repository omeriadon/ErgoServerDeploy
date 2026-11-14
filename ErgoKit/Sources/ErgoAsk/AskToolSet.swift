//
//  AskToolSet.swift
//  ErgoKit
//
//  Created by Adon Omeri on 8/11/2026.
//

import ErgoProtocol
import ErgoSync

/// What a tool call gives back: text for the model, and maybe something for whoever started the run to hear
public struct AskToolReply<Event: Sendable>: Sendable {
	public let text: String
	public let event: Event?

	public init(text: String, event: Event? = nil) {
		self.text = text
		self.event = event
	}
}

/// What `AskToolServer` serves: the tools a run offers, and how to run them. The JSON-RPC stays in the server, and
/// `Event` is what a run reports as its tools work: an answer's messages, or a board analysis's checked reports.
public protocol AskToolSet: Sendable {
	associatedtype Event: Sendable

	var definitions: [JSONValue] { get }

	/// Failures are worded for the model to put right
	func reply(to name: String, arguments: [String: JSONValue]) throws(AskTools.Failure) -> AskToolReply<Event>

	/// What to hear while a tool runs, before it has
	func event(running name: String, arguments: [String: JSONValue]) -> Event?
}

extension AskTools: AskToolSet {
	public var definitions: [JSONValue] {
		Self.definitions
	}

	public func reply(to name: String, arguments: [String: JSONValue]) throws(Failure) -> AskToolReply<AskServerMessage> {
		switch try call(name, arguments: arguments) {
			case let .text(text):
				AskToolReply(text: text)
			case let .action(action, text):
				AskToolReply(text: text, event: .action(action))
			case let .modeRequest(request, text):
				AskToolReply(text: text, event: .modeRequest(request))
		}
	}

	public func event(running name: String, arguments: [String: JSONValue]) -> AskServerMessage? {
		activity(name, arguments: arguments).map(AskServerMessage.tool)
	}
}
