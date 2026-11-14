//
//  BoardLedger+Analysis.swift
//  ErgoServer
//
//  Created by Adon Omeri on 8/11/2026.
//

import ErgoProtocol
import Fluent
import Foundation

/// What a board analysis writes: records only the server makes, on a board that may be shared
extension BoardLedger {
	/// Everyone whose row a record on this board goes in: every member of a shared board, else just `requester`
	mutating func audience(of board: String, requester: UUID, on database: any Database) async throws -> [UUID] {
		guard let shared = try await shared(board, on: database) else {
			return [requester]
		}
		return shared.members.map(\.$account.id)
	}

	/// Whether the board is a live record of this account, so a run on a deleted board, or one the person left, can stop
	func isLive(_ board: String, for account: UUID, on database: any Database) async throws -> Bool {
		guard let row = try await SyncRecordRow.find(SyncRecord.Key(kind: .board, id: board), for: account, on: database) else {
			return false
		}
		return row.tombstone == nil
	}

	/// Stores a record in every row of the audience. Each field gets a server stamp newer than the record's, and a record
	/// that was a tombstone comes back. A row that already says this isn't touched, so nobody's seq moves for nothing.
	mutating func writeServerOwned(
		_ kind: SyncKind,
		id: String,
		fields: [String: JSONValue],
		board: String,
		requester: UUID,
		on database: any Database
	) async throws {
		let key = SyncRecord.Key(kind: kind, id: id)
		for account in try await audience(of: board, requester: requester, on: database) {
			let row = try await SyncRecordRow.find(key, for: account, on: database)
			let stored = try row.map { try open($0) }
			var record = stored ?? SyncRecord(kind: kind, id: id)

			let stamp = SyncStamp.server(after: record.newestStamp, now: now)
			var updated = fields
			if record.isDeleted {
				updated[SyncFieldName.deleted] = .bool(false)
			}
			for (name, value) in updated where record.fields[name]?.value != value {
				record.fields[name] = SyncField(value: value, stamp: stamp)
			}
			if record != stored {
				try await store(record, in: row, of: account, on: database)
			}
		}
	}

	/// A server-stamped tombstone on every annotation of the board that another run made, for every member
	mutating func tombstoneAnnotations(of board: String, notFrom run: UUID, requester: UUID, on database: any Database) async throws {
		for account in try await audience(of: board, requester: requester, on: database) {
			let rows = try await SyncRecordRow.query(on: database)
				.filter(\.$account.$id == account)
				.filter(\.$kind == SyncKind.annotation.rawValue)
				.filter(\.$board == board)
				.all()
			for row in rows {
				let record = try open(row)
				// Content this version can't read isn't worth keeping either
				if record.isDeleted || BoardAnnotation(record)?.run == run {
					continue
				}
				try await tombstone(row.key, of: account, on: database)
			}
		}
	}
}
