//
//  PushDeviceRow.swift
//  ErgoServer
//
//  Created by Adon Omeri on 7/11/2026.
//

import Fluent
import Foundation

/// One device's APNs token, tied to its account token so signing out of a device stops its pushes
final class PushDeviceRow: Model, @unchecked Sendable {
	static let schema = "push_devices"

	@ID(key: .id)
	var id: UUID?

	@Parent(key: "account_id")
	var account: Account

	@Parent(key: "token_id")
	var token: AccountToken

	/// As hex, and never logged
	@Field(key: "apns_token")
	var apnsToken: String

	@Field(key: "updated")
	var updated: Date

	init() {}
}
