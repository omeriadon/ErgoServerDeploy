//
//  MoveAccountTokens.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import Fluent
import Foundation
import SQLKit

/// Moves each account's one token into `account_tokens`, then rebuilds `accounts` without `token_hash` and with
/// what sync needs. SQLite can't drop a unique column, and dropping a table while foreign keys are on deletes
/// every credential through the cascade, so the rebuild runs on one connection with them off. Postgres can just alter
/// the table, and has no tokens to move: its database has only ever run these migrations together, from empty.
struct MoveAccountTokens: AsyncMigration {
	private static let rebuilt = "accounts_rebuilt"

	func prepare(on database: any Database) async throws {
		try await database.withConnection { connection in
			guard let sql = connection as? any SQLDatabase else {
				throw ServerConfig.Problem(description: "Expected an SQL database to move account tokens")
			}

			guard sql.dialect.name == "sqlite" else {
				try await connection.transaction { database in
					try await alter(database)
				}
				return
			}

			// Only changes outside a transaction, and only for this connection
			let foreignKeys = try await sql.raw("PRAGMA foreign_keys").first()?.decode(column: "foreign_keys", as: Int.self) ?? 0
			try await sql.raw("PRAGMA foreign_keys = OFF").run()
			do {
				try await connection.transaction { database in
					try await rebuild(database)
				}
			} catch {
				do {
					try await sql.raw("PRAGMA foreign_keys = \(unsafeRaw: String(foreignKeys))").run()
				} catch {
					// This connection goes back to the pool without them, so deleting a row would no longer cascade
					database.logger.error("Couldn't turn foreign keys back on after a failed migration")
				}
				throw error
			}
			try await sql.raw("PRAGMA foreign_keys = \(unsafeRaw: String(foreignKeys))").run()
		}
	}

	private func alter(_ database: any Database) async throws {
		guard let sql = database as? any SQLDatabase else { return }

		try await sql.raw("ALTER TABLE accounts DROP COLUMN token_hash").run()
		try await sql.raw("ALTER TABLE accounts ADD COLUMN apple_subject TEXT").run()
		try await sql.raw("ALTER TABLE accounts ADD COLUMN seq BIGINT NOT NULL DEFAULT 0").run()
		try await sql.raw("ALTER TABLE accounts ADD COLUMN pruned_through BIGINT NOT NULL DEFAULT 0").run()
		try await sql.raw("ALTER TABLE accounts ADD CONSTRAINT \(ident: "uq:accounts.apple_subject") UNIQUE (apple_subject)").run()
	}

	private func rebuild(_ database: any Database) async throws {
		guard let sql = database as? any SQLDatabase else { return }

		let accounts = try await sql.raw("SELECT id FROM accounts").all().map { try $0.decode(column: "id", as: UUID.self) }
		for account in accounts {
			try await sql.raw("""
			INSERT INTO account_tokens (id, account_id, token_hash, created, last_seen)
			SELECT \(bind: UUID()), id, token_hash, created, last_seen FROM accounts WHERE id = \(bind: account)
			""").run()
		}

		try await database.schema(Self.rebuilt)
			.id()
			.field("created", .datetime, .required)
			.field("last_seen", .datetime, .required)
			.field("apple_subject", .string)
			.field("seq", .int, .required)
			.field("pruned_through", .int, .required)
			.unique(on: "apple_subject", name: "uq:accounts.apple_subject")
			.create()
		try await sql.raw("""
		INSERT INTO \(ident: Self.rebuilt) (id, created, last_seen, seq, pruned_through)
		SELECT id, created, last_seen, 0, 0 FROM accounts
		""").run()
		try await sql.raw("DROP TABLE accounts").run()
		try await sql.raw("ALTER TABLE \(ident: Self.rebuilt) RENAME TO accounts").run()

		// Every credential and token must still point at an account
		let broken = try await sql.raw("PRAGMA foreign_key_check").all()
		guard broken.isEmpty else {
			throw ServerConfig.Problem(description: "Expected every row to keep its account, found \(broken.count) without one")
		}
	}

	func revert(on _: any Database) async throws {
		throw ServerConfig.Problem(description: "MoveAccountTokens can't be reverted, restore a backup instead")
	}
}
