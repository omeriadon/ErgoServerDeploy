//
//  SyncController.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoProtocol
import Vapor

/// `POST v1/sync`, behind `SignedInWithApple`
enum SyncController {
	static func sync(_ request: Request) async throws -> Response {
		let account = try request.accountID
		guard request.ergo.syncLimits.allow(account) else {
			throw ServiceError(code: .rateLimited, message: "Too many syncs from this account, try again in a minute")
		}

		// The route collects at most this much, but a body that arrived whole skips that check
		let bytes = request.body.data?.readableBytes ?? 0
		guard bytes <= SyncLimit.requestBytes else {
			throw ServiceError(code: .tooLarge, message: "Expected a sync under \(SyncLimit.requestBytes >> 20) MB, found \(bytes >> 10) KB")
		}

		let body = try request.decode(SyncRequest.self)
		let response = try await request.ergo.sync.apply(
			body,
			account: account,
			token: request.tokenID,
			on: request.db,
			logger: request.logger
		)
		return try Response.json(response)
	}
}
