//
//  BoardRows.swift
//  ErgoServer
//
//  Created by Adon Omeri on 7/11/2026.
//

import ErgoProtocol
import Fluent
import Foundation

/// A shared board. Its id is the board's. Private boards have no row, so "is it shared" is whether there's one.
final class BoardShareRow: Model, @unchecked Sendable {
	static let schema = "board_shares"

	@ID(key: .id)
	var id: UUID?

	@Parent(key: "owner_id")
	var owner: Account

	/// What the owner's device last sent, sealed by `CredentialVault`. Records are sealed per account, so this is the
	/// only place previews and pushes can read a title from.
	@OptionalField(key: "sealed_title")
	var sealedTitle: Data?

	@Field(key: "created")
	var created: Date

	init() {}

	init(board: UUID, owner: UUID, sealedTitle: Data?, now: Date) {
		id = board
		$owner.id = owner
		self.sealedTitle = sealedTitle
		created = now
	}
}

/// Someone on a shared board, the owner included. Its id is the member id the app sees, so account ids stay private.
final class BoardMemberRow: Model, @unchecked Sendable {
	static let schema = "board_members"

	@ID(key: .id)
	var id: UUID?

	@Parent(key: "board_id")
	var board: BoardShareRow

	@Parent(key: "account_id")
	var account: Account

	/// A `BoardRole` raw value
	@Field(key: "role")
	var role: String

	/// What they chose to be called on this board. Never logged.
	@Field(key: "name")
	var name: String

	@Field(key: "joined")
	var joined: Date

	init() {}

	init(board: UUID, account: UUID, role: BoardRole, name: String, now: Date) {
		$board.id = board
		$account.id = account
		self.role = role.rawValue
		self.name = name
		joined = now
	}

	/// A role this version can't read can only view
	var boardRole: BoardRole {
		BoardRole(rawValue: role) ?? .viewer
	}
}

/// An open link. Only the token's hash is kept, so the database alone can't join anything.
final class BoardInviteRow: Model, @unchecked Sendable {
	static let schema = "board_invites"

	@ID(key: .id)
	var id: UUID?

	@Parent(key: "board_id")
	var board: BoardShareRow

	/// `Account.hash` of the token
	@Field(key: "token_hash")
	var tokenHash: String

	/// A `BoardRole` raw value, `editor` or `viewer`
	@Field(key: "role")
	var role: String

	@Field(key: "created")
	var created: Date

	@Field(key: "expires")
	var expires: Date

	init() {}

	init(board: UUID, tokenHash: String, role: BoardRole, now: Date, expires: Date) {
		$board.id = board
		self.tokenHash = tokenHash
		self.role = role.rawValue
		created = now
		self.expires = expires
	}

	var boardRole: BoardRole {
		BoardRole(rawValue: role) ?? .viewer
	}
}
