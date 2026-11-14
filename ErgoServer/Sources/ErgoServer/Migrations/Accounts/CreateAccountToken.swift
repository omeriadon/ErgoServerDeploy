//
//  CreateAccountToken.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import Fluent

struct CreateAccountToken: AsyncMigration {
	func prepare(on database: any Database) async throws {
		try await database.schema(AccountToken.schema)
			.id()
			.field("account_id", .uuid, .required, .references(Account.schema, .id, onDelete: .cascade))
			.field("token_hash", .string, .required)
			.field("created", .datetime, .required)
			.field("last_seen", .datetime, .required)
			.unique(on: "token_hash")
			.create()
	}

	func revert(on database: any Database) async throws {
		try await database.schema(AccountToken.schema).delete()
	}
}
