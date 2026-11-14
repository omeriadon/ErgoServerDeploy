//
//  DropPushDeviceEnvironment.swift
//  ErgoServer
//
//  Created by Adon Omeri on 7/11/2026.
//

import Fluent
import SQLKit

/// Pushes only ever go to Apple's production host, so a device no longer says which host its token works with. A sandbox
/// token can't work there, so those rows go too, and the device registers again if it ever gets a production token.
struct DropPushDeviceEnvironment: AsyncMigration {
	func prepare(on database: any Database) async throws {
		try await database.transaction { database in
			guard let sql = database as? any SQLDatabase else {
				throw ServerConfig.Problem(description: "Expected an SQL database to drop the push device environment")
			}
			try await sql.raw("DELETE FROM push_devices WHERE environment = 'sandbox'").run()
			try await sql.raw("ALTER TABLE push_devices DROP COLUMN environment").run()
		}
	}

	func revert(on _: any Database) async throws {
		throw ServerConfig.Problem(description: "DropPushDeviceEnvironment can't be reverted, restore a backup instead")
	}
}
