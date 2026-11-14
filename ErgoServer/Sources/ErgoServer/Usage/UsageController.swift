//
//  UsageController.swift
//  ErgoServer
//
//  Created by Adon Omeri on 10/11/2026.
//

import ErgoProtocol
import Fluent
import Vapor

/// `GET v1/usage`, `POST v1/account/plan` and `POST v1/account/device-claim`. Each answers with the account's
/// `UsageStatus` as it is afterwards. The quiet database handle, since a transaction id would be in Fluent's debug log.
enum UsageController {
	static func status(_ request: Request) async throws -> Response {
		let status = try await request.ergo.usage.status(of: request.accountID, on: request.quietDB)
		return try Response.json(status)
	}

	static func plan(_ request: Request) async throws -> Response {
		let body = try request.decode(PlanUpload.self)
		let account = try request.accountID
		try await request.ergo.usage.activate(body, for: account, on: request.quietDB, logger: request.logger)
		return try await Response.json(request.ergo.usage.status(of: account, on: request.quietDB))
	}

	static func claim(_ request: Request) async throws -> Response {
		let body = try request.decode(DeviceClaimUpload.self)
		let account = try request.accountID
		try await request.ergo.usage.claimDevice(body, for: account, on: request.quietDB, logger: request.logger)
		return try await Response.json(request.ergo.usage.status(of: account, on: request.quietDB))
	}
}
