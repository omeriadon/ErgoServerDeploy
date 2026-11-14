//
//  SyncRequest.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import Foundation

// The body and reply of `POST v1/sync`. They live here rather than in ErgoProtocol because `SyncReplica` makes and
// applies them, and ErgoSync has no dependencies.

/// Local edits to one record. One round trip pushes these and pulls everything after `cursor`.
public struct SyncChange: Codable, Sendable, Hashable {
	public var kind: SyncKind
	public var id: String

	/// Only the fields that changed
	public var fields: [String: SyncField]

	/// For each field, the stamp of the value it was edited from. Missing for a field that didn't exist.
	/// The server calls an edit concurrent when what it has is neither this nor the edit itself.
	public var bases: [String: SyncStamp]

	public init(kind: SyncKind, id: String, fields: [String: SyncField], bases: [String: SyncStamp] = [:]) {
		self.kind = kind
		self.id = id
		self.fields = fields
		self.bases = bases
	}

	public var key: SyncRecord.Key {
		SyncRecord.Key(kind: kind, id: id)
	}

	public var record: SyncRecord {
		SyncRecord(kind: kind, id: id, fields: fields)
	}
}

public struct SyncRequest: Codable, Sendable, Hashable {
	/// The response's cursor from last time. Nil pulls from the start.
	public var cursor: Int?
	public var changes: [SyncChange]

	/// Most records to return. The server defaults to 500 and caps it at 1000.
	public var limit: Int?

	public init(cursor: Int?, changes: [SyncChange], limit: Int? = nil) {
		self.cursor = cursor
		self.changes = changes
		self.limit = limit
	}
}

/// The losing side of a concurrent edit, sent only to the device that pushed it, so a copy is made exactly once
public struct SupersededField: Codable, Sendable, Hashable {
	public var kind: SyncKind
	public var id: String
	public var field: String

	/// Either the pushed value or the one the server had, whichever lost the merge
	public var lost: SyncField

	public init(kind: SyncKind, id: String, field: String, lost: SyncField) {
		self.kind = kind
		self.id = id
		self.field = field
		self.lost = lost
	}

	public var key: SyncRecord.Key {
		SyncRecord.Key(kind: kind, id: id)
	}
}

/// A pushed record the server refused, because it's on a board this account may not edit: a viewer, or someone removed
/// whose device hasn't heard yet. The rest of the request still goes through.
public struct RejectedChange: Codable, Sendable, Hashable {
	public var kind: SyncKind
	public var id: String

	/// What the server has, nil when it has nothing
	public var current: SyncRecord?

	public init(kind: SyncKind, id: String, current: SyncRecord? = nil) {
		self.kind = kind
		self.id = id
		self.current = current
	}

	public var key: SyncRecord.Key {
		SyncRecord.Key(kind: kind, id: id)
	}
}

public struct SyncResponse: Codable, Sendable, Hashable {
	/// Send it next time: the seq of the last record in `changes` while there's `more`, then the account's latest seq
	public var cursor: Int

	/// Every record changed after the request's cursor, merged, including the ones just pushed.
	/// On a shared board that includes what other members pushed.
	public var changes: [SyncRecord]

	/// More records after these: ask again with the new cursor straight away
	public var more: Bool

	/// The losing sides of concurrent fields in the request's changes. Only the device that pushed gets these.
	public var superseded: [SupersededField]

	/// The request's changes the server refused. Optional on the wire, so nil unless there are some: an older app ignores
	/// them and an older server never sends them. Only the device that pushed gets these.
	public var rejected: [RejectedChange]?

	/// What corrects this device's clock
	public var serverTime: Date

	public init(cursor: Int, changes: [SyncRecord], more: Bool, superseded: [SupersededField] = [], rejected: [RejectedChange]? = nil, serverTime: Date) {
		self.cursor = cursor
		self.changes = changes
		self.more = more
		self.superseded = superseded
		self.rejected = rejected
		self.serverTime = serverTime
	}
}
