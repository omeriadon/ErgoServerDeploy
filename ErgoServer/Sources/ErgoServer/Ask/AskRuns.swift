//
//  AskRuns.swift
//  ErgoServer
//
//  Created by Adon Omeri on 6/11/2026.
//

import ErgoProtocol
import Foundation
import Synchronization

/// The asks and board analyses running right now, each under a random token. A CLI reaches its run's tools with that
/// token in the URL, so what its tools do ends up in the right run. A run's responder says what its tools do, and a
/// token only reads the library and reports to its own run. It's gone when the run is.
final class AskRuns: Sendable {
	/// A JSON-RPC message in, and what to say back, which is empty for a notification
	typealias Responder = @Sendable (Data) async -> Data

	/// What an ask hears of its answer, to send on
	typealias Listener = @Sendable (AskServerMessage) async -> Void

	private let runs = Mutex<[String: Responder]>([:])

	func register(_ responder: @escaping Responder) -> String {
		let token = (0 ..< 32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
		runs.withLock { $0[token] = responder }
		return token
	}

	func remove(_ token: String) {
		runs.withLock { _ = $0.removeValue(forKey: token) }
	}

	func responder(for token: String) -> Responder? {
		runs.withLock { $0[token] }
	}
}
