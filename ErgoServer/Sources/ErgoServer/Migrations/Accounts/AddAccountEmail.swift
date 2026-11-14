//
//  AddAccountEmail.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import Fluent
import SQLKit

/// Adds the email and its bcrypt hash to `accounts`, both empty until someone registers. Unlike `MoveAccountTokens`
/// this needs no rebuild: SQLite adds a nullable column in place, and a unique index (which allows any number of
/// NULLs) does what a unique constraint would. The table isn't dropped, so credentials and tokens keep their account
/// with foreign keys on. It runs in a transaction, so a failure leaves the old schema.
struct AddAccountEmail: AsyncMigration {
	func prepare(on database: any Database) async throws {
		try await database.transaction { database in
			guard let sql = database as? any SQLDatabase else {
				throw ServerConfig.Problem(description: "Expected an SQL database to add account emails")
			}
			try await sql.raw("ALTER TABLE accounts ADD COLUMN email TEXT").run()
			try await sql.raw("ALTER TABLE accounts ADD COLUMN password_hash TEXT").run()
			try await sql.create(index: "uq:accounts.email").unique().on(Account.schema).column("email").run()
		}
	}

	func revert(on _: any Database) async throws {
		throw ServerConfig.Problem(description: "AddAccountEmail can't be reverted, restore a backup instead")
	}
}
