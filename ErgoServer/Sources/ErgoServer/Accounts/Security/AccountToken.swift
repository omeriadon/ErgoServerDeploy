//
//  AccountToken.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import Fluent
import Foundation
import Vapor

/// One device's bearer token, so one device can sign out without the others. Only its hash is kept,
/// so the database alone can't sign anyone in.
final class AccountToken: Model, Authenticatable, @unchecked Sendable {
	static let schema = "account_tokens"

	@ID(key: .id)
	var id: UUID?

	@Parent(key: "account_id")
	var account: Account

	@Field(key: "token_hash")
	var tokenHash: String

	@Field(key: "created")
	var created: Date

	@Field(key: "last_seen")
	var lastSeen: Date

	init() {}

	init(account: UUID, tokenHash: String, now: Date = .now) {
		$account.id = account
		self.tokenHash = tokenHash
		created = now
		lastSeen = now
	}

	/// In constant time, so a timing difference can't leak how much of a hash matched
	func matches(tokenHash other: String) -> Bool {
		let mine = Array(tokenHash.utf8)
		let theirs = Array(other.utf8)
		guard mine.count == theirs.count else { return false }
		return zip(mine, theirs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
	}
}
