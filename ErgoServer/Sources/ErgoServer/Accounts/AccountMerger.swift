//
//  AccountMerger.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoProtocol
import Fluent
import Foundation
import Logging

/// Folds a device's account into the account that already has its Apple ID or email, when a second device signs in.
/// Nothing is lost: connections move where the target has none, and records merge like a sync.
struct AccountMerger {
	let vault: CredentialVault
	let logger: Logger

	/// Inside the caller's transaction, with the target locked. Moves `token` to `target`, then deletes `source`.
	/// Returns whether any of the target's records changed, so its other devices can be told.
	func merge(_ source: Account, into target: Account, token: AccountToken, on database: any Database, now: Date = .now) async throws -> Bool {
		let sourceID = try source.requireID()
		let targetID = try target.requireID()

		// Signing in only merges an anonymous account, so this can't happen. If it ever did, an email on the
		// source would be deleted with it and its owner could never use it again.
		guard source.email == nil else {
			throw ServiceError(code: .invalidRequest, message: "Already signed in with an email, sign out first")
		}

		try await moveCredentials(from: sourceID, to: targetID, on: database)
		let changed = try await mergeRecords(from: sourceID, into: target, on: database, now: now)
		try await moveAppleRefreshToken(from: source, to: target, on: database)

		token.$account.id = targetID
		try await token.save(on: database)

		// Anonymous, so on no boards, and nobody to tell
		try await AccountController.deleteEverything(of: sourceID, vault: vault, logger: logger, on: database)
		return changed
	}

	// MARK: - Connections

	/// Only for providers the target has none for, so the first device's connection is never replaced.
	/// They're sealed to their account, so each is opened and sealed again.
	private func moveCredentials(from source: UUID, to target: UUID, on database: any Database) async throws {
		let connected = try await Set(Credential.query(on: database).filter(\.$account.$id == target).all().map(\.provider))
		let credentials = try await Credential.query(on: database).filter(\.$account.$id == source).all()

		for credential in credentials where !connected.contains(credential.provider) {
			do {
				let secret = try vault.open(credential.sealed, account: source, provider: credential.provider)
				credential.sealed = try vault.seal(secret, account: target, provider: credential.provider)
			} catch {
				logger.error("Couldn't unseal a credential to move it", metadata: ["provider": "\(credential.provider)"])
				continue
			}
			credential.$account.id = target
			try await credential.save(on: database)
		}
	}

	// MARK: - Apple

	/// An anonymous account has none, so this only keeps a merge from ever being what loses the way to revoke a sign-in.
	/// The target's own stays when it has one. Sealed to its account, so it's opened and sealed again.
	private func moveAppleRefreshToken(from source: Account, to target: Account, on database: any Database) async throws {
		guard target.appleRefreshToken == nil, let sealed = source.appleRefreshToken else { return }

		do {
			let token = try vault.openAppleRefreshToken(sealed, account: source.requireID())
			target.appleRefreshToken = try vault.seal(appleRefreshToken: token, account: target.requireID())
		} catch {
			logger.error("Couldn't unseal Apple's refresh token to move it")
			return
		}
		try await target.save(on: database)
	}

	// MARK: - Records

	/// Normally there are none, since anonymous accounts don't sync, but a merge must never drop someone's writing
	private func mergeRecords(from source: UUID, into target: Account, on database: any Database, now: Date) async throws -> Bool {
		let targetID = try target.requireID()
		let rows = try await SyncRecordRow.query(on: database).filter(\.$account.$id == source).sort(\.$seq).all()

		var changed = false
		for row in rows {
			let incoming: SyncRecord
			do {
				incoming = try row.record(vault)
			} catch {
				logger.error("Couldn't unseal a synced record to merge it", metadata: ["kind": "\(row.kind)", "seq": "\(row.seq)"])
				throw ServiceError.internalFailure
			}

			let existing = try await SyncRecordRow.find(row.key, for: targetID, on: database)
			let stored = try existing.map { try $0.record(vault) }
			let merged = stored.map { SyncRecord.merge($0, incoming) } ?? incoming
			guard merged != stored else { continue }

			target.seq += 1
			let updated = existing ?? SyncRecordRow(account: targetID, key: row.key)
			try updated.store(merged, seq: target.seq, vault: vault, now: now)
			try await updated.save(on: database)
			changed = true
		}

		if changed {
			try await target.save(on: database)
		}
		return changed
	}
}
