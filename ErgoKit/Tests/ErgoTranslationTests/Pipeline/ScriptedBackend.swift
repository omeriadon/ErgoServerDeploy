//
//  ScriptedBackend.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoTranslation
import Foundation
import Synchronization

/// Answers each stage from a script of JSON, the same shape a server sends back
final class ScriptedBackend: TranslationBackend {
	let policy: TranslationPolicy
	private let state: Mutex<(replies: [String: [String]], requests: [(stage: String, input: String)])>

	init(_ replies: [String: [String]], policy: TranslationPolicy = TranslationPolicy()) {
		self.policy = policy
		state = Mutex((replies, []))
	}

	var requests: [(stage: String, input: String)] {
		state.withLock(\.requests)
	}

	func count(_ stage: String) -> Int {
		requests.filter { $0.stage == stage }.count
	}

	/// The last request's input for a stage, as JSON
	func lastInput(_ stage: String) -> String {
		requests.last { $0.stage == stage }?.input ?? ""
	}

	func run<Stage: TranslationStage>(_: Stage.Type, _ input: Stage.Input) async throws -> Stage.Output {
		let request = try String(decoding: JSONEncoder().encode(input), as: UTF8.self)

		let reply = state.withLock { state in
			state.requests.append((Stage.name, request))
			guard var queue = state.replies[Stage.name], !queue.isEmpty else { return String?.none }
			let reply = queue.removeFirst()
			state.replies[Stage.name] = queue.isEmpty ? [reply] : queue
			return reply
		}

		guard let reply else {
			throw ScriptError(stage: Stage.name)
		}
		return try JSONDecoder().decode(Stage.Output.self, from: Data(reply.utf8))
	}

	struct ScriptError: Error {
		let stage: String
	}
}

/// Collects what the pipeline announces
final class EventLog: Sendable {
	private let events = Mutex<[TranslationEvent]>([])

	var all: [TranslationEvent] {
		events.withLock(\.self)
	}

	func record(_ event: TranslationEvent) {
		events.withLock { $0.append(event) }
	}
}
