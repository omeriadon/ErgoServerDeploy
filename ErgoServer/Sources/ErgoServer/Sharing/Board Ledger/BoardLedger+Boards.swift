//
//  BoardLedger+Boards.swift
//  Ergo
//
//  Created by Adon Omeri on 8/11/2026.
//

import ErgoProtocol
import Fluent
import Foundation
import Logging

extension BoardLedger {
	// MARK: - Boards

	/// Nil when it isn't shared. Anyone who joined since the locks were taken is locked now.
	mutating func shared(_ key: String, on database: any Database) async throws -> SharedBoard? {
		if let known = shares[key] {
			return known
		}
		if unshared.contains(key) {
			return nil
		}
		// Only ever an uppercase UUID, so a board field spelled another way can't reach a shared board
		guard let id = UUID(uuidString: key), id.uuidString == key, let share = try await BoardShareRow.find(id, on: database) else {
			unshared.insert(key)
			return nil
		}
		let members = try await BoardMemberRow.query(on: database).filter(\.$board.$id == id).all()
		try await lock(members.map(\.$account.id), on: database)
		let board = SharedBoard(key: key, share: share, members: members)
		shares[key] = board
		return board
	}

	/// A board this transaction just shared
	mutating func adopt(_ board: SharedBoard) {
		shares[board.key] = board
		unshared.remove(board.key)
	}

	mutating func add(_ member: BoardMemberRow, to key: String) {
		shares[key]?.members.append(member)
	}

	// MARK: - Writing

	/// Stores `record` in the account's row, as its next seq
	mutating func store(_ record: SyncRecord, in row: SyncRecordRow?, of id: UUID, on database: any Database) async throws {
		if accounts[id] == nil {
			try await lock([id], on: database)
		}
		guard let account = accounts[id] else { return }

		account.seq += 1
		let updated = row ?? SyncRecordRow(account: id, key: record.key)
		try updated.store(record, seq: account.seq, vault: vault, now: now)
		try await updated.save(on: database)
		changed.insert(id)
	}

	/// Unsealing only fails with the wrong key or a damaged row. Logs which kind, never what's in it.
	func open(_ row: SyncRecordRow) throws -> SyncRecord {
		do {
			return try row.record(vault)
		} catch {
			logger.error("Couldn't unseal a synced record", metadata: ["kind": "\(row.kind)", "seq": "\(row.seq)"])
			throw ServiceError.internalFailure
		}
	}

	/// A server-stamped tombstone. Nothing else about the record changes, and a record that's already one stays as it is.
	mutating func tombstone(_ key: SyncRecord.Key, of account: UUID, on database: any Database) async throws {
		let row = try await SyncRecordRow.find(key, for: account, on: database)
		var record = try row.map { try open($0) } ?? SyncRecord(kind: key.kind, id: key.id)
		guard !record.isDeleted else { return }

		record.fields[SyncFieldName.deleted] = SyncField(value: .bool(true), stamp: .server(after: record.newestStamp, now: now))
		try await store(record, in: row, of: account, on: database)
	}

	/// Brings every member's `share` record up to date, leaving alone any that already says this
	mutating func writeShares(of board: SharedBoard, on database: any Database) async throws {
		let everyone = board.everyone
		for member in board.members {
			let share = try BoardShare(board: board.key, role: member.boardRole, member: member.requireID(), members: everyone)
			let key = SyncRecord.Key(kind: .share, id: board.key)
			let row = try await SyncRecordRow.find(key, for: member.$account.id, on: database)
			var record = try row.map { try open($0) } ?? SyncRecord(kind: .share, id: board.key)
			if BoardShare(record) == share {
				continue
			}

			// One stamp, newer than any tombstone it had, which is what brings back the share of someone rejoining
			let stamp = SyncStamp.server(after: record.newestStamp, now: now)
			for (name, value) in share.fields {
				record.fields[name] = SyncField(value: value, stamp: stamp)
			}
			try await store(record, in: row, of: member.$account.id, on: database)
		}
	}
}
