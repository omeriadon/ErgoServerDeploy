//
//  CreateAccount.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import Fluent

struct CreateAccount: AsyncMigration {
	func prepare(on database: any Database) async throws {
		try await database.schema(Account.schema)
			.id()
			.field("token_hash", .string, .required)
			.field("created", .datetime, .required)
			.field("last_seen", .datetime, .required)
			.unique(on: "token_hash")
			.create()
	}

	func revert(on database: any Database) async throws {
		try await database.schema(Account.schema).delete()
	}
}
