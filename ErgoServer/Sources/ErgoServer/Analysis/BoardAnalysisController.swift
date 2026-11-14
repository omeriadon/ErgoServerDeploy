//
//  BoardAnalysisController.swift
//  ErgoServer
//
//  Created by Adon Omeri on 8/11/2026.
//

import ErgoProtocol
import Fluent
import Vapor

/// `POST v1/boards/<id>/analysis` (up to 2 MB, a board's cards and the text of its sources) starts a run and answers 202 straight away: the run carries on without the request,
/// and what it finds arrives as sync records. `DELETE` stops it. Behind `RequireSignedIn`, with the quiet database
/// handle since a board's text is people's writing.
enum BoardAnalysisController {
	static func start(_ request: Request) async throws -> Response {
		let body = try request.decode(BoardAnalysisRequest.self)
		let application = request.application
		let port = application.http.server.shared.localAddress?.port ?? application.http.server.configuration.port
		let account = try request.accountID

		// The job outlives this request, so it gets the application's database and logger, never the request's
		try await request.ergo.analyses.start(
			body,
			board: request.parameters.get("board"),
			account: account,
			port: port,
			database: request.quietDB,
			logger: request.logger,
			jobDatabase: application.db,
			jobLogger: request.jobLogger(for: account)
		)
		return Response(status: .accepted)
	}

	/// Nothing running is as good as stopped
	static func stop(_ request: Request) async throws -> Response {
		try request.ergo.analyses.stop(board: request.parameters.get("board"), account: request.accountID)
		request.logger.verbose("Stopped a board analysis")
		return Response(status: .noContent)
	}
}
