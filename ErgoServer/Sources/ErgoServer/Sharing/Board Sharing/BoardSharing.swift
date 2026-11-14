//
//  BoardSharing.swift
//  ErgoServer
//
//  Created by Adon Omeri on 7/11/2026.
//

import ErgoProtocol
import Fluent
import Foundation
import Logging

/// Invites, members and stopping. Each member keeps their own copy of a board's records, sealed for their account, and
/// `SyncService` copies every change to the others, so a member's device does nothing different from any other sync.
///
/// See `Plans/09-Sharing.md`. Never logs a token, a title or a name.
struct BoardSharing: Sendable {
	let vault: CredentialVault
	let live: SyncLive
	let push: PushService

	/// `ServerConfig.publicURL`, what invite links are built on
	let publicURL: String

	static let inviteLifetime: TimeInterval = 30 * 24 * 60 * 60
	static let invitesPerBoard = 20
	static let titleCharacters = 200
	static let nameCharacters = 60

	// MARK: - Locks

	/// Who a push could write to, read before its transaction so they can all be locked in order: everyone on any board it
	/// touches, the caller among them. Inside the transaction the membership is read again.
	func accounts(touchedBy changes: [SyncChange], caller: UUID, on database: any Database) async throws -> Set<UUID> {
		var boards = Set<String>()
		var others: [String] = []
		for change in changes {
			if change.kind == .board {
				boards.insert(change.id)
			} else {
				others.append(change.id)
				if let board = change.record.owningBoard {
					boards.insert(board)
				}
			}
		}
		// An edit only carries the fields that changed, so usually only the stored row says what board it's on
		for start in stride(from: 0, to: others.count, by: 500) {
			let rows = try await SyncRecordRow.query(on: database)
				.filter(\.$account.$id == caller)
				.filter(\.$recordID ~~ others[start ..< min(start + 500, others.count)])
				.field(\.$board)
				.all()
			boards.formUnion(rows.compactMap(\.board))
		}

		let accounts = try await members(of: boards.compactMap { UUID(uuidString: $0) }, on: database)
		return Set(accounts).union([caller])
	}

	/// Everyone on a board with this account, read before the transaction that deletes it, so they can be locked in order
	func accounts(sharingWith account: UUID, on database: any Database) async throws -> [UUID] {
		let boards = try await BoardMemberRow.query(on: database)
			.filter(\.$account.$id == account)
			.field(\.$board.$id)
			.all()
			.map(\.$board.id)
		return try await members(of: boards, on: database)
	}

	func members(of boards: [UUID], on database: any Database) async throws -> [UUID] {
		var accounts: [UUID] = []
		for start in stride(from: 0, to: boards.count, by: 500) {
			let rows = try await BoardMemberRow.query(on: database)
				.filter(\.$board.$id ~~ boards[start ..< min(start + 500, boards.count)])
				.field(\.$account.$id)
				.all()
			accounts += rows.map(\.$account.id)
		}
		return accounts
	}

	/// One change to a board's people, or to what the server writes on it: its members and the caller locked in order, the
	/// body's writes in one transaction, and live messages and pushes only after it commits.
	func change<Value: Sendable>(
		board: UUID,
		caller: UUID,
		token: UUID?,
		on database: any Database,
		logger: Logger,
		now: Date,
		_ body: @escaping @Sendable (inout BoardLedger, any Database) async throws -> Value
	) async throws -> Value {
		let everyone = try await members(of: [board], on: database)
		let vault = vault
		let (value, effects) = try await database.transaction { database in
			var ledger = BoardLedger(vault: vault, logger: logger, now: now)
			try await ledger.lock(everyone + [caller], on: database)
			let value = try await body(&ledger, database)
			let effects = try await ledger.finish(on: database)
			return (value, effects)
		}
		await finish(effects, caller: caller, token: token, on: database, logger: logger)
		return value
	}

	/// After a commit. The pushing token already knows what it did, and every other socket hears its own account's seq.
	func finish(_ effects: BoardLedger.Effects, caller: UUID?, token: UUID?, on database: any Database, logger: Logger) async {
		for (account, cursor) in effects.cursors {
			live.changed(account: account, cursor: cursor, except: account == caller ? token : nil)
		}
		await push.deliver(effects.pushes, on: database, logger: logger)
	}
}

extension ServiceError {
	static let inviteClosed = ServiceError(code: .invalidRequest, message: "Expected an invite that's still open, found one that expired or was revoked")
	static let notBoardOwner = ServiceError(code: .invalidRequest, message: "Expected a board you own, found one someone else shared")
}
