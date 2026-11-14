//
//  Credential.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoProtocol
import Fluent
import Foundation

/// One provider connection for one account, sealed by `CredentialVault`
final class Credential: Model, @unchecked Sendable {
	static let schema = "credentials"

	@ID(key: .id)
	var id: UUID?

	@Parent(key: "account_id")
	var account: Account

	@Field(key: "provider")
	var provider: Provider

	@Field(key: "kind")
	var kind: CredentialKind

	@Field(key: "sealed")
	var sealed: Data

	/// When a call with it last succeeded
	@OptionalField(key: "verified")
	var verified: Date?

	/// Why the last call failed, shown in the app's Settings
	@OptionalField(key: "problem")
	var problem: String?

	@Field(key: "updated")
	var updated: Date

	init() {}

	init(account: UUID, provider: Provider, kind: CredentialKind, sealed: Data, verified: Date?, problem: String?, now: Date = .now) {
		$account.id = account
		self.provider = provider
		self.kind = kind
		self.sealed = sealed
		self.verified = verified
		self.problem = problem
		updated = now
	}

	var status: ConnectionStatus {
		ConnectionStatus(provider: provider, kind: kind, verified: verified, problem: problem)
	}

	static func find(_ provider: Provider, for account: UUID, on database: any Database) async throws -> Credential? {
		try await Credential.query(on: database)
			.filter(\.$account.$id == account)
			.filter(\.$provider == provider)
			.first()
	}

	// MARK: - Updates during a translation

	// By id, since the row may have been replaced or deleted while the CLI ran

	static func markWorking(_ id: UUID, now: Date = .now, on database: any Database) async throws {
		try await Credential.query(on: database)
			.filter(\.$id == id)
			.set(\.$verified, to: now)
			.set(\.$problem, to: nil)
			.update()
	}

	static func mark(_ id: UUID, problem: String, on database: any Database) async throws {
		try await Credential.query(on: database)
			.filter(\.$id == id)
			.set(\.$problem, to: problem)
			.update()
	}

	/// Codex refreshed its tokens, so the old ones may already be spent
	static func reseal(_ id: UUID, with sealed: Data, now: Date = .now, on database: any Database) async throws {
		try await Credential.query(on: database)
			.filter(\.$id == id)
			.set(\.$sealed, to: sealed)
			.set(\.$updated, to: now)
			.update()
	}
}
