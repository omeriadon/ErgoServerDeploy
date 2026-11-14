//
//  CreateSyncRecord.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import Fluent
import SQLKit

struct CreateSyncRecord: AsyncMigration {
	func prepare(on database: any Database) async throws {
		try await database.schema(SyncRecordRow.schema)
			.id()
			.field("account_id", .uuid, .required, .references(Account.schema, .id, onDelete: .cascade))
			.field("kind", .string, .required)
			.field("record_id", .string, .required)
			.field("fields", .data, .required)
			.field("seq", .int, .required)
			.field("tombstone", .datetime)
			.field("updated", .datetime, .required)
			.unique(on: "account_id", "kind", "record_id")
			.create()

		guard let sql = database as? any SQLDatabase else { return }
		// Every sync reads an account's rows after a cursor, and pruning looks for old tombstones
		try await sql.create(index: "sync_records_account_seq").on(SyncRecordRow.schema).column("account_id").column("seq").run()
		try await sql.create(index: "sync_records_tombstone").on(SyncRecordRow.schema).column("tombstone").run()
	}

	func revert(on database: any Database) async throws {
		try await database.schema(SyncRecordRow.schema).delete()
	}
}
