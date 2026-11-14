//
//  TranslateSocket.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoProtocol
import ErgoTranslation
import Foundation
import NIOCore
import Vapor

/// `WS v1/translate`: waits for one request, sends each pipeline event as it happens, then the translation, and closes.
/// Sending `.cancel` or closing the socket cancels the work, which stops the CLI.
///
/// Except for an argument (Break Down), which is a detached run (`DetachedRuns`): it carries on if the socket closes, so
/// a force quit app finds the breakdown when it comes back by sending the same request again. Only `.cancel` stops it.
struct TranslateSocket {
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

		// Proxies drop a quiet connection, and a translation can take a minute
		socket.pingInterval = TimeAmount(request.ergo.config.pingInterval)
	}

	func run() async {
		let config = request.ergo.config
		guard let account = try? request.accountID else {
			return await finish(.failed(.unknownAccount))
		}
		socket.logClosing("Translate", logger: request.logger)

		let timer = Task {
			do {
				try await Task.sleep(for: config.requestWait)
				input.yield(.waitedTooLong)
			} catch {}
		}

		// Only this loop touches these, and they last until the socket closes
		var work: Task<Void, Never>?
		var run: UUID?
		var forwarding: Task<Void, Never>?
		for await message in incoming {
			switch message {
				case .waitedTooLong:
					if work == nil, run == nil {
						request.logger.warning("A translate socket sent no request", metadata: ["waited": "\(config.requestWait.spelledOut)"])
						await finish(.failed(ServiceError(
							code: .timedOut,
							message: "Expected a translate request within \(config.requestWait.spelledOut)"
						)))
					}

				case let .text(text):
					switch try? ErgoProtocol.decoder.decode(TranslateClientMessage.self, from: Data(text.utf8)) {
						case let .translate(translate)? where work == nil && run == nil:
							timer.cancel()
							switch translate.scope {
								case .statement:
									work = Task {
										await self.translate(translate, account: account)
									}
								case .argument:
									do {
										let stream = try startBreakDown(translate, account: account)
										run = translate.id
										forwarding = Task {
											await forward(stream)
										}
									} catch {
										request.logger.warning("Couldn't start a breakdown", metadata: ["code": "\((error as? ServiceError)?.code.rawValue ?? "internalError")"])
										// Coded like a breakdown's own failure
										await finish(.failed(error as? ServiceError ?? .internalFailure))
									}
							}
						case .translate?:
							// The protocol has one request per socket, so a second one changes nothing
							break
						case .cancel?:
							request.logger.verbose("Cancelled a translation")
							if let run {
								request.ergo.detached.cancel(run: run, account: account)
							} else if let work {
								work.cancel()
							} else {
								await close()
							}
						case nil where work == nil && run == nil:
							request.logger.warning("A translate socket sent something that isn't a request")
							await finish(.failed(ServiceError(code: .invalidRequest, message: "Expected a translate request")))
						case nil:
							break
					}
			}
		}

		timer.cancel()
		work?.cancel()
		await work?.value
		// Only this connection stops listening. A breakdown carries on without it.
		forwarding?.cancel()
	}

	/// Starts the breakdown, or joins it when the account already has a run with this id. It outlives this request, so it
	/// uses the application's database and logger, never the request's.
	private func startBreakDown(_ translate: TranslateRequest, account: UUID) throws -> AsyncStream<String> {
		let application = request.application
		let service = request.ergo.translations
		let database = application.db
		let logger = request.jobLogger(for: account)

		return try request.ergo.detached.start(run: translate.id, account: account) { emit in
			let say: @Sendable (BreakDownServerMessage) -> Void = { message in
				if let data = try? ErgoProtocol.encoder.encode(message) {
					emit(String(decoding: data, as: UTF8.self))
				}
			}

			do {
				let breakdown = try await service.breakDown(translate, account: account, database: database, logger: logger) { event in
					say(.event(event))
				}
				say(.finished(breakdown))
			} catch {
				// Whoever cancelled has stopped listening
				guard !Task.isCancelled, !(error is CancellationError) else { return }
				say(.failed(error as? ServiceError ?? .internalFailure))
			}
		}
	}

	/// Sends what the run says to this socket, and closes it when the run is over
	private func forward(_ stream: AsyncStream<String>) async {
		for await text in stream {
			try? await socket.send(text)
		}
		await close()
	}

	/// A statement, which ends with a `Translation`. Only Evals asks for one, and it stops when the socket closes.
	private func translate(_ translate: TranslateRequest, account: UUID) async {
		let service = request.ergo.translations
		await answer(TranslateServerMessage.finished, failed: TranslateServerMessage.failed, event: TranslateServerMessage.event) { events in
			try await service.translate(translate, account: account, database: request.db, logger: request.logger, events: events)
		}
	}

	private func answer<Result, Message: Encodable & Sendable>(
		_ finished: (Result) -> Message,
		failed: (ServiceError) -> Message,
		event: @escaping @Sendable (TranslationEvent) -> Message,
		_ work: (@escaping @Sendable (TranslationEvent) async -> Void) async throws -> Result
	) async {
		let reply: Message
		do {
			reply = try await finished(work { await send(event($0)) })
		} catch {
			// Whoever cancelled has stopped listening
			guard !Task.isCancelled, !(error is CancellationError) else {
				return await close()
			}
			reply = failed(error as? ServiceError ?? .internalFailure)
		}
		await send(reply)
		await close()
	}

	// MARK: - Sending

	private func send(_ message: some Encodable) async {
		guard let data = try? ErgoProtocol.encoder.encode(message) else { return }
		try? await socket.send(String(decoding: data, as: UTF8.self))
	}

	/// Before the request is known, so before there's a scope to answer in
	private func finish(_ message: TranslateServerMessage) async {
		await send(message)
		await close()
	}

	private func close() async {
		try? await socket.close(code: .normalClosure)
	}
}
