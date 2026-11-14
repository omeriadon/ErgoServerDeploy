//
//  AddAppleRefreshToken.swift
//  ErgoServer
//
//  Created by Adon Omeri on 10/11/2026.
//

import Fluent

/// Adds the sealed Sign in with Apple refresh token to `accounts`, empty until someone signs in with a code to trade.
/// A plain Fluent schema change, so it's the same on SQLite and Postgres, and a nullable column needs no rebuild.
struct AddAppleRefreshToken: AsyncMigration {
	func prepare(on database: any Database) async throws {
		try await database.schema(Account.schema)
			.field("apple_refresh_token", .data)
			.update()
	}

	func revert(on _: any Database) async throws {
		throw ServerConfig.Problem(description: "AddAppleRefreshToken can't be reverted, restore a backup instead")
	}
}
