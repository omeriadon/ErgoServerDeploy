//
//  PushController.swift
//  ErgoServer
//
//  Created by Adon Omeri on 7/11/2026.
//

import ErgoProtocol
import Fluent
import Vapor

/// `PUT` and `DELETE v1/push/device`, behind `RequireSignedIn`. The quiet database handle, so Fluent's debug log can't
/// print an APNs token.
enum PushController {
	/// Device tokens are 32 bytes today, and Apple says to allow for up to 100
	static let maxTokenCharacters = 200

	/// One row per APNs token and one per account token: a device that changed either replaces what it had, and a phone
	/// that signed in to another account moves over.
	static func register(_ request: Request) async throws -> Response {
		let body = try request.decode(PushDevice.self)
		// It goes in the path of a request to Apple, so only ever hex
		let apnsToken = body.token.lowercased()
		guard !apnsToken.isEmpty, apnsToken.count <= maxTokenCharacters, apnsToken.allSatisfy(\.isHexDigit) else {
			throw ServiceError(code: .invalidRequest, message: "Expected an APNs device token in hex")
		}

		let account = try request.accountID
		let token = try request.tokenID
		try await request.quietDB.transaction { database in
			try await PushDeviceRow.query(on: database).filter(\.$token.$id == token).filter(\.$apnsToken != apnsToken).delete()

			let row = try await PushDeviceRow.query(on: database).filter(\.$apnsToken == apnsToken).first() ?? PushDeviceRow()
			row.$account.id = account
			row.$token.id = token
			row.apnsToken = apnsToken
			row.updated = .now
			try await row.save(on: database)
		}
		request.logger.verbose("Registered a push device")
		return Response(status: .noContent)
	}

	/// Only this device's token, so signing out of notifications here leaves the account's other devices alone
	static func unregister(_ request: Request) async throws -> Response {
		let token = try request.tokenID
		try await PushDeviceRow.query(on: request.quietDB).filter(\.$token.$id == token).delete()
		request.logger.verbose("Forgot a push device")
		return Response(status: .noContent)
	}
}
