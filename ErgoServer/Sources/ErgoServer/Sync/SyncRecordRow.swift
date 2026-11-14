//
//  SyncRecordRow.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoProtocol
import Fluent
import Foundation

/// One synced record of one account. Its fields are people's writing, so they're sealed like credentials,
/// and only opened to merge.
final class SyncRecordRow: Model, @unchecked Sendable {
	static let schema = "sync_records"

	@ID(key: .id)
	var id: UUID?

	@Parent(key: "account_id")
	var account: Account

	@Field(key: "kind")
	var kind: String

	@Field(key: "record_id")
	var recordID: String

	/// `[String: SyncField]` as JSON, sealed by `CredentialVault`
	@Field(key: "fields")
	var fields: Data

	/// The account's seq when this record last changed
	@Field(key: "seq")
	var seq: Int

	/// The `deleted` stamp's time while the record is a tombstone, so pruning needn't open every row
	@OptionalField(key: "tombstone")
	var tombstone: Date?

	/// A statement's or link's `board` field, so pruning can find a deleted board's leftovers without opening every row
	@OptionalField(key: "board_id")
	var board: String?

	@Field(key: "updated")
	var updated: Date

	init() {}

	init(account: UUID, key: SyncRecord.Key) {
		$account.id = account
		kind = key.kind.rawValue
		recordID = key.id
	}

	var key: SyncRecord.Key {
		SyncRecord.Key(kind: SyncKind(rawValue: kind), id: recordID)
	}

	// MARK: - Sealing

	func record(_ vault: CredentialVault) throws -> SyncRecord {
		try SyncRecord(kind: key.kind, id: key.id, fields: vault.open(fields, account: $account.id, record: key))
	}

	/// Seals `record` into this row as change number `seq`
	func store(_ record: SyncRecord, seq: Int, vault: CredentialVault, now: Date = .now) throws {
		fields = try vault.seal(record.fields, account: $account.id, record: key)
		self.seq = seq
		tombstone = record.isDeleted ? record.fields[SyncFieldName.deleted]?.stamp.date : nil
		board = record.owningBoard
		updated = now
	}

	static func find(_ key: SyncRecord.Key, for account: UUID, on database: any Database) async throws -> SyncRecordRow? {
		try await SyncRecordRow.query(on: database)
			.filter(\.$account.$id == account)
			.filter(\.$kind == key.kind.rawValue)
			.filter(\.$recordID == key.id)
			.first()
	}
}
