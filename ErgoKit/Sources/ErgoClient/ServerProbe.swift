//
//  ServerProbe.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoProtocol
import Foundation
#if canImport(FoundationNetworking)
	import FoundationNetworking
#endif

public extension ErgoClient {
	/// What checking the server found, once for REST and once for a socket, since one can work while the other doesn't
	struct Probe: Sendable, Hashable {
		public enum Outcome: Sendable, Hashable {
			case ok

			/// The server answered, but turned the request away for having no account it knows
			case noAccount

			case failed(ServiceError)
		}

		public var rest: Outcome
		public var socket: Outcome

		public init(rest: Outcome, socket: Outcome) {
			self.rest = rest
			self.socket = socket
		}
	}

	/// Asks for this account's connections, then opens the translate socket and cancels straight after the upgrade,
	/// without sending a request. It never makes an account: without a token both are turned away, which still shows
	/// the server was reached. Throws only `CancellationError`.
	func probe(timeout: TimeInterval = 10) async throws -> Probe {
		let rest = try await probeREST(timeout: timeout)
		let socket = try await probeSocket(timeout: timeout)
		return Probe(rest: rest, socket: socket)
	}

	private func probeREST(timeout: TimeInterval) async throws -> Probe.Outcome {
		var request = request("GET", ErgoProtocol.Path.connections)
		request.timeoutInterval = timeout
		do {
			_ = try await data(for: request)
			return .ok
		} catch let error as ServiceError {
			return error.code == .unauthorized ? .noAccount : .failed(error)
		}
	}

	private func probeSocket(timeout: TimeInterval) async throws -> Probe.Outcome {
		var request = socketRequest(ErgoProtocol.Path.translate)
		request.timeoutInterval = timeout
		let socket = session.webSocketTask(with: request)
		socket.resume()
		defer { socket.cancel(with: .normalClosure, reason: nil) }

		// A cancel with nothing running only makes the server close, and a send only goes out over an upgraded socket.
		// A ping's pong never came back from Vapor in testing, so it can't stand in.
		do {
			try await withTaskCancellationHandler {
				try await socket.send(.string(Self.text(TranslateClientMessage.cancel) ?? ""))
			} onCancel: {
				socket.cancel()
			}
		} catch {
			try Task.checkCancellation()
			let failure = Self.failure(of: socket, error)
			return failure.code == .unauthorized ? .noAccount : .failed(failure)
		}
		return .ok
	}
}
