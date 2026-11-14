//
//  CreateUsage.swift
//  ErgoServer
//
//  Created by Adon Omeri on 10/11/2026.
//

import Fluent

/// What each account has used of the server's own model, and what it has paid for. Plain Fluent schema, so it's the same
/// on SQLite and Postgres.
struct CreateUsage: AsyncMigration {
	func prepare(on database: any Database) async throws {
		try await database.schema(UsagePeriodRow.schema)
			.id()
			.field("account_id", .uuid, .required, .references(Account.schema, .id, onDelete: .cascade))
			.field("period", .string, .required)
			.field("micros", .int, .required)
			.field("runs", .int, .required)
			.unique(on: "account_id", "period")
			.create()

		try await database.schema(AccountPlanRow.schema)
			.id()
			.field("account_id", .uuid, .required, .references(Account.schema, .id, onDelete: .cascade))
			.field("plan", .string, .required)
			.field("expires", .datetime)
			.field("original_transaction", .string)
			.field("device_claimed", .datetime)
			.unique(on: "account_id")
			.create()
	}

	func revert(on database: any Database) async throws {
		try await database.schema(AccountPlanRow.schema).delete()
		try await database.schema(UsagePeriodRow.schema).delete()
	}
}
