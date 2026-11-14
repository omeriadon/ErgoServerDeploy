//
//  TranslationSession.swift
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
	/// Events as they happen, finishing with the translation. Cancelling the consuming task cancels the work on the server.
	///
	/// The server's own failures arrive as `.failed`, the last message. Thrown errors mean the server couldn't be reached
	/// or dropped the connection.
	///
	/// Always runs the `.statement` scope, whatever `request.scope` says. Use `breakDown` for an argument.
	func translate(_ request: TranslateRequest) -> AsyncThrowingStream<TranslateServerMessage, Error> {
		var request = request
		request.scope = .statement
		return messages(
			at: ErgoProtocol.Path.translate,
			opening: Self.text(TranslateClientMessage.translate(request)),
			closing: Self.text(TranslateClientMessage.cancel)
		) { message in
			switch message {
				case .event:
					false
				case .finished, .failed:
					true
			}
		}
	}

	/// Breaks pasted English into premises, a conclusion and claims, without writing any logic: events as they
	/// happen, finishing with the breakdown. The request's `descriptors` are what the board already calls its letters,
	/// and come back filled in with the new claims. Cancelling the consuming task cancels the work on the server.
	///
	/// The work is the server's: if the connection drops it carries on, and sending the same request again (same `id`)
	/// hears it from the start.
	///
	/// Always runs the `.argument` scope, whatever `request.scope` says.
	func breakDown(_ request: TranslateRequest) -> AsyncThrowingStream<BreakDownServerMessage, Error> {
		var request = request
		request.scope = .argument
		return messages(
			at: ErgoProtocol.Path.translate,
			opening: Self.text(TranslateClientMessage.translate(request)),
			closing: Self.text(TranslateClientMessage.cancel)
		) { message in
			switch message {
				case .event:
					false
				case .finished, .failed:
					true
			}
		}
	}
}

public extension ErgoClient {
	/// The answer as it's written, what its tools do and the buttons it adds, finishing with `.finished`. Cancelling the
	/// consuming task cancels the work on the server.
	///
	/// The answer is the server's: if the connection drops it carries on, and sending the same request again (same `id`)
	/// hears it from the start.
	///
	/// The server's own failures arrive as `.failed`, the last message. Thrown errors mean the server couldn't be reached
	/// or dropped the connection.
	func ask(_ request: AskRequest) -> AsyncThrowingStream<AskServerMessage, Error> {
		messages(
			at: ErgoProtocol.Path.ask,
			opening: Self.text(AskClientMessage.ask(request)),
			closing: Self.text(AskClientMessage.cancel)
		) { message in
			switch message {
				case .finished, .failed:
					true
				default:
					false
			}
		}
	}
}
