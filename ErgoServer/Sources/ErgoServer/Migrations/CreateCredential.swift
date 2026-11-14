//
//  CreateCredential.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import Fluent

struct CreateCredential: AsyncMigration {
	func prepare(on database: any Database) async throws {
		try await database.schema(Credential.schema)
			.id()
			.field("account_id", .uuid, .required, .references(Account.schema, .id, onDelete: .cascade))
			.field("provider", .string, .required)
			.field("kind", .string, .required)
			.field("sealed", .data, .required)
			.field("verified", .datetime)
			.field("problem", .string)
			.field("updated", .datetime, .required)
			.unique(on: "account_id", "provider")
			.create()
	}

	func revert(on database: any Database) async throws {
		try await database.schema(Credential.schema).delete()
	}
}
