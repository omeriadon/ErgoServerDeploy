//
//  AskToolController.swift
//  ErgoServer
//
//  Created by Adon Omeri on 6/11/2026.
//

import ErgoProtocol
import Vapor

/// `v1/ask/tools/<token>`, where a CLI answering an ask, or analysing a board, calls Ergo's tools over MCP. It's only ever this machine's CLI,
/// but the route is as reachable as any other, so the run's random token is what guards it.
enum AskToolController {
	static func isToolCall(_ request: Request) -> Bool {
		request.url.path.hasPrefix("/\(ErgoProtocol.Path.askTools)/")
	}

	static func receive(_ request: Request) async throws -> Response {
		guard let token = request.parameters.get("token"), let responder = request.ergo.ask.runs.responder(for: token) else {
			throw Abort(.notFound)
		}
		let body = request.body.data.map { Data($0.readableBytesView) } ?? Data()
		let reply = await responder(body)

		// Nothing to say back to a notification
		guard !reply.isEmpty else {
			return Response(status: .accepted)
		}
		var headers = HTTPHeaders()
		headers.contentType = .json
		return Response(status: .ok, headers: headers, body: .init(data: reply))
	}

	/// MCP clients try a GET for server messages and a DELETE to end the session. This server has neither, and saying so
	/// is how they find that out.
	static func refuse(_: Request) async throws -> Response {
		Response(status: .methodNotAllowed)
	}
}
