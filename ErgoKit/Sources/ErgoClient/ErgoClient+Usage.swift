//
//  ErgoClient+Usage.swift
//  ErgoKit
//
//  Created by Adon Omeri on 10/11/2026.
//

import ErgoProtocol
import Foundation

public extension ErgoClient {
	// MARK: - Usage

	/// How much of Ergo's model this account has left today
	func usage() async throws -> UsageStatus {
		try await send(request("GET", ErgoProtocol.Path.usage))
	}

	/// `transaction` is an App Store transaction as Apple signed it, StoreKit's `jwsRepresentation`
	func uploadPlan(transaction: String) async throws -> UsageStatus {
		try await send(request("POST", ErgoProtocol.Path.plan, body: PlanUpload(transaction: transaction)))
	}

	/// `token` is a DeviceCheck token, in base64
	func claimDevice(token: String) async throws -> UsageStatus {
		try await send(request("POST", ErgoProtocol.Path.deviceClaim, body: DeviceClaimUpload(token: token)))
	}
}
