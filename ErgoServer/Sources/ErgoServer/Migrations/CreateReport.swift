//
//  CreateReport.swift
//  ErgoServer
//
//  Created by Adon Omeri on 10/11/2026.
//

import Fluent

/// What members have reported about shared boards. Plain Fluent schema, so it's the same on SQLite and Postgres.
struct CreateReport: AsyncMigration {
	func prepare(on database: any Database) async throws {
		try await database.schema(ReportRow.schema)
			.id()
			.field("created", .datetime, .required)
			.field("reporter_id", .uuid, .required)
			.field("board_id", .uuid, .required)
			.field("owner_id", .uuid, .required)
			.field("reason", .string, .required)
			.field("handled", .datetime)
			.create()
	}

	func revert(on database: any Database) async throws {
		try await database.schema(ReportRow.schema).delete()
	}
}
