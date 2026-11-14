//
//  BoardSharingController.swift
//  ErgoServer
//
//  Created by Adon Omeri on 7/11/2026.
//

import ErgoProtocol
import Fluent
import Vapor

/// The routes for sharing a board, behind `RequireSignedIn` but for a preview. They all use the quiet database handle,
/// since Fluent's debug log prints the values of every query: names, token hashes and APNs tokens would be in it.
enum BoardSharingController {
	static func createInvite(_ request: Request) async throws -> Response {
		let body = try request.decode(CreateBoardInvite.self)
		// Sharing is on the paid plan. Joining a board someone else shared never is.
		try await request.ergo.usage.requirePlus(request.accountID, for: "Sharing a board", on: request.quietDB)
		let invite = try await request.ergo.sharing.createInvite(
			body,
			board: request.parameters.get("board"),
			account: request.accountID,
			token: request.tokenID,
			on: request.quietDB,
			logger: request.logger
		)
		return try Response.json(invite)
	}

	static func revokeInvites(_ request: Request) async throws -> Response {
		try await request.ergo.sharing.revokeInvites(
			board: request.parameters.get("board"),
			account: request.accountID,
			token: request.tokenID,
			on: request.quietDB,
			logger: request.logger
		)
		return Response(status: .noContent)
	}

	static func updateMember(_ request: Request) async throws -> Response {
		let body = try request.decode(UpdateBoardMember.self)
		try await request.ergo.sharing.updateMember(
			board: request.parameters.get("board"),
			member: request.parameters.get("member"),
			role: body.role,
			account: request.accountID,
			token: request.tokenID,
			on: request.quietDB,
			logger: request.logger
		)
		return Response(status: .noContent)
	}

	static func removeMember(_ request: Request) async throws -> Response {
		try await request.ergo.sharing.removeMember(
			board: request.parameters.get("board"),
			member: request.parameters.get("member"),
			account: request.accountID,
			token: request.tokenID,
			on: request.quietDB,
			logger: request.logger
		)
		return Response(status: .noContent)
	}

	static func stopSharing(_ request: Request) async throws -> Response {
		try await request.ergo.sharing.stopSharing(
			board: request.parameters.get("board"),
			account: request.accountID,
			token: request.tokenID,
			on: request.quietDB,
			logger: request.logger
		)
		return Response(status: .noContent)
	}

	static func report(_ request: Request) async throws -> Response {
		let body = try request.decode(ReportBoard.self)
		try await BoardReports.file(
			body,
			board: request.parameters.get("board"),
			account: request.accountID,
			limiter: request.ergo.reportLimiter,
			on: request.quietDB,
			logger: request.logger
		)
		return Response(status: .noContent)
	}

	/// No auth, since someone without an account yet sees it, so limited per address
	static func preview(_ request: Request) async throws -> Response {
		guard request.ergo.invitePreviewLimiter.allow(request.clientAddress) else {
			throw ServiceError(code: .rateLimited, message: "Too many invite previews from this address, try again in a minute")
		}
		let body = try request.decode(BoardInviteToken.self)
		return try await Response.json(request.ergo.sharing.preview(body, on: request.quietDB))
	}

	static func accept(_ request: Request) async throws -> Response {
		let body = try request.decode(AcceptBoardInvite.self)
		let joined = try await request.ergo.sharing.accept(
			body,
			account: request.accountID,
			token: request.tokenID,
			on: request.quietDB,
			logger: request.logger
		)
		return try Response.json(joined)
	}
}
