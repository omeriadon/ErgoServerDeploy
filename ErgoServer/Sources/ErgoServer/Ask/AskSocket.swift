//
//  AskSocket.swift
//  ErgoServer
//
//  Created by Adon Omeri on 6/11/2026.
//

import ErgoProtocol
import Fluent
import Foundation
import Logging
import NIOCore
import Vapor

/// `WS v1/ask`: waits for one request, sends the answer as it's written and what its tools do, then `.finished`, and closes.
///
/// The answer is a detached run (`DetachedRuns`), so it carries on if the socket closes, which is how a force quit app
/// finds it when it comes back: it sends the same request again, and the run's id says it's the same one. Only
/// `.cancel` stops the CLI.
struct AskSocket {
	let request: Request
	let socket: WebSocket

	private enum Incoming: Sendable {
		case text(String)
		case waitedTooLong
	}

	private let incoming: AsyncStream<Incoming>
	private let input: AsyncStream<Incoming>.Continuation

	/// Only on the socket's event loop, straight after the upgrade, so nothing the client sends first is missed
	init(request: Request, socket: WebSocket) {
		self.request = request
		self.socket = socket
		(incoming, input) = AsyncStream.makeStream(of: Incoming.self)

		let input = input
		socket.onText { _, text in
			input.yield(.text(text))
		}
		socket.onBinary { _, buffer in
			input.yield(.text(String(buffer: buffer)))
		}
		socket.onClose.whenComplete { _ in
			input.finish()
		}

		// Proxies drop a quiet connection, and the model can think for a while between tool calls
		socket.pingInterval = TimeAmount(request.ergo.config.pingInterval)
	}

	func run() async {
		let config = request.ergo.config
		guard let account = try? request.accountID else {
			return await finish(.failed(.unknownAccount))
		}
		socket.logClosing("Ask", logger: request.logger)

		let timer = Task {
			do {
				try await Task.sleep(for: config.requestWait)
				input.yield(.waitedTooLong)
			} catch {}
		}

		// Only this loop touches these, and they last until the socket closes
		var run: UUID?
		var forwarding: Task<Void, Never>?
		for await message in incoming {
			switch message {
				case .waitedTooLong:
					if run == nil {
						request.logger.warning("An ask socket sent no request", metadata: ["waited": "\(config.requestWait.spelledOut)"])
						await finish(.failed(ServiceError(
							code: .timedOut,
							message: "Expected an ask request within \(config.requestWait.spelledOut)"
						)))
					}

				case let .text(text):
					switch try? ErgoProtocol.decoder.decode(AskClientMessage.self, from: Data(text.utf8)) {
						case let .ask(ask)? where run == nil:
							timer.cancel()
							do {
								let stream = try start(ask, account: account)
								run = ask.id
								forwarding = Task {
									await forward(stream)
								}
							} catch {
								request.logger.warning("Couldn't start an ask", metadata: ["code": "\((error as? ServiceError)?.code.rawValue ?? "internalError")"])
								await finish(.failed(error as? ServiceError ?? .internalFailure))
							}
						case .ask?:
							// The protocol has one request per socket, so a second one changes nothing
							break
						case .cancel?:
							request.logger.verbose("Cancelled an ask")
							if let run {
								request.ergo.detached.cancel(run: run, account: account)
							} else {
								await close()
							}
						case nil where run == nil:
							request.logger.warning("An ask socket sent something that isn't a request")
							await finish(.failed(ServiceError(code: .invalidRequest, message: "Expected an ask request")))
						case nil:
							break
					}
			}
		}

		timer.cancel()
		// Only this connection stops listening. The run carries on without it.
		forwarding?.cancel()
	}

	/// Starts the answer, or joins it when the account already has a run with this id. It outlives this request, so it
	/// uses the application's database and logger, never the request's.
	private func start(_ ask: AskRequest, account: UUID) throws -> AsyncStream<String> {
		let application = request.application
		let port = application.http.server.shared.localAddress?.port ?? application.http.server.configuration.port
		let service = request.ergo.ask
		let database = application.db
		let logger = request.jobLogger(for: account)

		return try request.ergo.detached.start(run: ask.id, account: account) { emit in
			await Self.answer(ask, account: account, port: port, service: service, database: database, logger: logger, emit: emit)
		}
	}

	private static func answer(
		_ ask: AskRequest,
		account: UUID,
		port: Int,
		service: AskService,
		database: any Database,
		logger: Logger,
		emit: @escaping DetachedRuns.Emit
	) async {
		let say: @Sendable (AskServerMessage) -> Void = { message in
			if let data = try? ErgoProtocol.encoder.encode(message) {
				emit(String(decoding: data, as: UTF8.self))
			}
		}

		do {
			try await service.ask(ask, port: port, account: account, database: database, logger: logger) { message in
				say(message)
			}
			say(.finished)
		} catch {
			// Whoever cancelled has stopped listening
			guard !Task.isCancelled, !(error is CancellationError) else { return }
			say(.failed(error as? ServiceError ?? .internalFailure))
		}
	}

	/// Sends what the run says to this socket, and closes it when the run is over
	private func forward(_ stream: AsyncStream<String>) async {
		for await text in stream {
			try? await socket.send(text)
		}
		await close()
	}

	// MARK: - Sending

	private func send(_ message: AskServerMessage) async {
		guard let data = try? ErgoProtocol.encoder.encode(message) else { return }
		try? await socket.send(String(decoding: data, as: UTF8.self))
	}

	private func finish(_ message: AskServerMessage) async {
		await send(message)
		await close()
	}

	private func close() async {
		try? await socket.close(code: .normalClosure)
	}
}
