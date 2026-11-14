//
//  CreateBoardSharing.swift
//  ErgoServer
//
//  Created by Adon Omeri on 7/11/2026.
//

import Fluent
import SQLKit

/// Who's on which shared board, the links to join them, and where to send pushes. Plain Fluent schema, so it's the same
/// on SQLite and Postgres.
struct CreateBoardSharing: AsyncMigration {
	func prepare(on database: any Database) async throws {
		try await database.schema(BoardShareRow.schema)
			.id()
			.field("owner_id", .uuid, .required, .references(Account.schema, .id, onDelete: .cascade))
			.field("sealed_title", .data)
			.field("created", .datetime, .required)
			.create()

		try await database.schema(BoardMemberRow.schema)
			.id()
			.field("board_id", .uuid, .required, .references(BoardShareRow.schema, .id, onDelete: .cascade))
			.field("account_id", .uuid, .required, .references(Account.schema, .id, onDelete: .cascade))
			.field("role", .string, .required)
			.field("name", .string, .required)
			.field("joined", .datetime, .required)
			.unique(on: "board_id", "account_id")
			.create()

		try await database.schema(BoardInviteRow.schema)
			.id()
			.field("board_id", .uuid, .required, .references(BoardShareRow.schema, .id, onDelete: .cascade))
			.field("token_hash", .string, .required)
			.field("role", .string, .required)
			.field("created", .datetime, .required)
			.field("expires", .datetime, .required)
			.unique(on: "token_hash")
			.create()

		try await database.schema(PushDeviceRow.schema)
			.id()
			.field("account_id", .uuid, .required, .references(Account.schema, .id, onDelete: .cascade))
			.field("token_id", .uuid, .required, .references(AccountToken.schema, .id, onDelete: .cascade))
			.field("apns_token", .string, .required)
			.field("environment", .string, .required)
			.field("updated", .datetime, .required)
			.unique(on: "apns_token")
			.create()

		guard let sql = database as? any SQLDatabase else { return }
		// Every board an account is on, the links of a board, and the devices a push goes to
		try await sql.create(index: "board_members_account").on(BoardMemberRow.schema).column("account_id").run()
		try await sql.create(index: "board_invites_board").on(BoardInviteRow.schema).column("board_id").run()
		try await sql.create(index: "push_devices_account").on(PushDeviceRow.schema).column("account_id").run()
		try await sql.create(index: "push_devices_token").on(PushDeviceRow.schema).column("token_id").run()
	}

	func revert(on database: any Database) async throws {
		try await database.schema(PushDeviceRow.schema).delete()
		try await database.schema(BoardInviteRow.schema).delete()
		try await database.schema(BoardMemberRow.schema).delete()
		try await database.schema(BoardShareRow.schema).delete()
	}
}
