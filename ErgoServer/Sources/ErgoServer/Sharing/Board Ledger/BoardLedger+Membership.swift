//
//  BoardLedger+Membership.swift
//  Ergo
//
//  Created by Adon Omeri on 8/11/2026.
//

import ErgoProtocol
import Fluent
import Foundation
import Logging

extension BoardLedger {
	// MARK: - Joining

	/// Copies a board's records from its owner's account to a joiner's, sealed for them. Fan-out isn't counted against the
	/// record limit, and neither is this.
	mutating func copyBoard(_ key: String, from owner: UUID, to joiner: UUID, on database: any Database) async throws {
		// Only `created`: `deleted` is per person
		let boardKey = SyncRecord.Key(kind: .board, id: key)
		let ownersBoard = try await SyncRecordRow.find(boardKey, for: owner, on: database).map { try open($0) }
		let theirs = try await SyncRecordRow.find(boardKey, for: joiner, on: database)
		let stored = try theirs.map { try open($0) }
		var record = stored ?? SyncRecord(kind: .board, id: key)
		if let created = ownersBoard?.fields[SyncFieldName.created] {
			record.merge([SyncFieldName.created: created])
		}
		// A tombstone from before, for them only. Without any field at all the device wouldn't see a board.
		if record.isDeleted || record.fields.isEmpty {
			record.fields[SyncFieldName.deleted] = SyncField(value: .bool(false), stamp: .server(after: record.newestStamp, now: now))
		}
		if record != stored {
			try await store(record, in: theirs, of: joiner, on: database)
		}

		let rows = try await SyncRecordRow.query(on: database)
			.filter(\.$account.$id == owner)
			.filter(\.$board == key)
			.sort(\.$seq)
			.all()
		for row in rows {
			let existing = try await SyncRecordRow.find(row.key, for: joiner, on: database)
			// A tombstone only matters to someone who already has the record, from when they were here before
			if row.tombstone != nil, existing == nil {
				continue
			}
			// Their own record that happens to share an id, on another board
			if let existing, existing.board != key {
				continue
			}

			let incoming = try open(row)
			let stored = try existing.map { try open($0) }
			let merged = stored.map { SyncRecord.merge($0, incoming) } ?? incoming
			if merged != stored {
				try await store(merged, in: existing, of: joiner, on: database)
			}
		}
	}

	// MARK: - Leaving

	/// Someone stops being on a board, and everyone else's `members` is rewritten. `tombstoningBoard` is for being removed:
	/// someone leaving has already written their own, and an account being deleted is about to lose its rows anyway.
	mutating func remove(
		_ member: BoardMemberRow,
		from key: String,
		tombstoningBoard: Bool,
		tombstoningShare: Bool = true,
		on database: any Database
	) async throws {
		let account = member.$account.id
		let memberID = try member.requireID()
		try await BoardMemberRow.query(on: database).filter(\.$id == memberID).delete()
		shares[key]?.members.removeAll { $0.id == memberID }

		if tombstoningBoard {
			try await tombstone(SyncRecord.Key(kind: .board, id: key), of: account, on: database)
		}
		if tombstoningShare {
			try await tombstone(SyncRecord.Key(kind: .share, id: key), of: account, on: database)
		}
		if let board = shares[key] {
			try await writeShares(of: board, on: database)
		}
	}

	/// Everyone else loses the board, the owner's own copy going too when `deletingOwnersBoard`. A board that was only
	/// just shared has no `others`, so tells nobody.
	mutating func end(
		_ board: SharedBoard,
		heading: String,
		deletingOwnersBoard: Bool,
		ownerGoing: Bool = false,
		on database: any Database
	) async throws {
		let ownerID = board.share.$owner.id
		let others = board.others(than: ownerID)
		let boardKey = SyncRecord.Key(kind: .board, id: board.key)
		let shareKey = SyncRecord.Key(kind: .share, id: board.key)
		for account in others {
			try await tombstone(boardKey, of: account, on: database)
			try await tombstone(shareKey, of: account, on: database)
		}
		if !ownerGoing {
			if deletingOwnersBoard {
				try await tombstone(boardKey, of: ownerID, on: database)
			}
			try await tombstone(shareKey, of: ownerID, on: database)
		}

		let id = try board.share.requireID()
		try await BoardInviteRow.query(on: database).filter(\.$board.$id == id).delete()
		try await BoardMemberRow.query(on: database).filter(\.$board.$id == id).delete()
		try await BoardShareRow.query(on: database).filter(\.$id == id).delete()
		shares[board.key] = nil
		unshared.insert(board.key)
		edited[board.key] = nil

		if !others.isEmpty {
			pushes.append(PushEvent(board: board.key, heading: heading, title: board.title(vault), recipients: others))
		}
	}

	/// Everything an account being deleted leaves behind on other people's boards: the boards it owns go for everyone, and it
	/// leaves the rest. Its own rows are the caller's to delete, so nothing is written to them.
	mutating func removeAccount(_ account: UUID, on database: any Database) async throws {
		let memberships = try await BoardMemberRow.query(on: database).filter(\.$account.$id == account).all()
		for membership in memberships {
			let key = membership.$board.id.uuidString
			guard let board = try await shared(key, on: database) else { continue }

			if board.share.$owner.id == account {
				try await end(board, heading: "\(membership.name) deleted", deletingOwnersBoard: false, ownerGoing: true, on: database)
			} else {
				try await remove(membership, from: key, tombstoningBoard: false, tombstoningShare: false, on: database)
			}
		}
	}
}
