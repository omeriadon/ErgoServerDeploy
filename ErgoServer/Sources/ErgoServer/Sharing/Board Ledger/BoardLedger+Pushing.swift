//
//  BoardLedger+Pushing.swift
//  Ergo
//
//  Created by Adon Omeri on 8/11/2026.
//

import ErgoProtocol
import Fluent
import Foundation
import Logging

extension BoardLedger {
	// MARK: - Pushing to a shared board

	enum Access: Sendable {
		/// Not on a shared board, so as ever
		case plain

		/// Refused, with what this account has
		case rejected

		/// Goes into the caller's own row, then `applied` works out what it means for everyone else
		case shared(String)
	}

	/// Whether this account may make this change. Every change belongs to a board: a board record's own id, or the stored
	/// row's `board`, else the incoming one, so a new kind on a board is covered without naming it.
	mutating func access(for change: SyncChange, row: SyncRecordRow?, account: UUID, on database: any Database) async throws -> Access {
		let incoming = change.record.owningBoard

		// A record moving between boards can't be fanned out right to either side
		if change.kind != .board, let stored = row?.board, change.fields[SyncFieldName.board] != nil, incoming != stored {
			if try await shared(stored, on: database) != nil {
				return .rejected
			}
			if let incoming, try await shared(incoming, on: database) != nil {
				return .rejected
			}
			return .plain
		}

		let owning: String? = change.kind == .board ? change.id : (row?.board ?? incoming)
		guard let key = owning, let board = try await shared(key, on: database) else {
			return .plain
		}
		if board.member(of: account)?.boardRole.canEdit == true {
			return .shared(key)
		}
		// Leaving works for anyone, offline included. For someone not on the board it only touches their own row.
		if change.kind == .board, change.fields.count == 1, change.fields[SyncFieldName.deleted]?.value == .bool(true) {
			return .shared(key)
		}
		return .rejected
	}

	/// After the change went into the caller's row and actually changed it
	mutating func applied(_ record: SyncRecord, access: Access, account: UUID, on database: any Database) async throws {
		guard case let .shared(key) = access, let board = try await shared(key, on: database) else { return }
		let member = board.member(of: account)

		if record.kind == .board, record.isDeleted {
			guard let member else { return }
			if member.boardRole == .owner {
				try await end(board, heading: "\(member.name) deleted", deletingOwnersBoard: true, on: database)
			} else {
				try await remove(member, from: key, tombstoningBoard: false, on: database)
			}
			return
		}

		guard member?.boardRole.canEdit == true else { return }
		try await fanOut(record, board: board, from: account, on: database)
	}

	/// Merges into every other member's row with the same key, each taking its own account's next seq. The record limit
	/// isn't checked, so no one's limit can fail someone else's push.
	mutating func fanOut(_ record: SyncRecord, board: SharedBoard, from account: UUID, on database: any Database) async throws {
		var outgoing = record
		if record.kind == .board {
			// `deleted` is per person
			outgoing.fields = record.fields.filter { $0.key == SyncFieldName.created }
			guard !outgoing.fields.isEmpty else { return }
		}

		for target in board.others(than: account) {
			let row = try await SyncRecordRow.find(record.key, for: target, on: database)
			// So an editor can't reach a record on a board they aren't on by reusing its id
			if let row, record.kind != .board, row.board != board.key {
				continue
			}

			let stored: SyncRecord?
			do {
				stored = try row.map { try open($0) }
			} catch {
				// Their damaged row is no reason to fail this person's push
				continue
			}
			let merged = stored.map { SyncRecord.merge($0, outgoing) } ?? outgoing
			if merged != stored {
				try await store(merged, in: row, of: target, on: database)
				edited[board.key] = account
			}
		}
	}
}
