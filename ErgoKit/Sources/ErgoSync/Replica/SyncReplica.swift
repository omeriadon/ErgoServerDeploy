//
//  SyncReplica.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import Foundation

/// The device's side of sync. A plain value the app saves; it knows nothing about boards.
///
/// The app hands `recordLocal` the current fields of a record after every change, sends `makeRequest()`,
/// and gives the reply to `apply`, which says which records to write back and which values lost.
///
/// Invariants:
/// - Every field in `pending` is in `records` with the same stamp. A remote value that beats an unsent edit
///   replaces it in both, and `apply` reports the edit as superseded, so typing is never dropped silently.
/// - A field leaves `pending` only once a request carrying that exact stamp has been answered.
/// - Every stamp the clock makes is newer than every stamp in `records`.
/// - Tombstones leave `records` once they're older than `SyncLimit.tombstoneDays`, like on the server.
public struct SyncReplica: Sendable, Hashable {
	/// The last merged state of each record, local edits included. It's the base for the next edit.
	public internal(set) var records: [SyncRecord.Key: SyncRecord]

	/// Local edits the server hasn't acknowledged yet
	public internal(set) var pending: [SyncRecord.Key: SyncChange]

	/// The last response's cursor. Nil pulls everything.
	public internal(set) var cursor: Int?

	public internal(set) var clock: SyncClock

	/// Local values recorded before this replica first caught up, so possibly just a new install's defaults.
	/// When the full pull completes they fill in only the fields the server doesn't have. Nil once caught up.
	public internal(set) var seeds: [SyncRecord.Key: SyncRecord]?

	/// After `reset`, the records the full pull hasn't returned yet. When it completes, the server doesn't have
	/// these, so they're pushed as they are.
	public internal(set) var unconfirmed: Set<SyncRecord.Key>?

	public init(
		records: [SyncRecord.Key: SyncRecord] = [:],
		pending: [SyncRecord.Key: SyncChange] = [:],
		cursor: Int? = nil,
		clock: SyncClock,
		seeds: [SyncRecord.Key: SyncRecord]? = [:],
		unconfirmed: Set<SyncRecord.Key>? = nil
	) {
		self.records = records
		self.pending = pending
		self.cursor = cursor
		self.clock = clock
		self.seeds = seeds
		self.unconfirmed = unconfirmed
	}

	/// A new install. `device` is a random id made once per install and kept.
	public init(device: String) {
		self.init(clock: SyncClock(device: device))
	}

	public var device: String {
		clock.device
	}

	/// Whether a full pull has completed since this replica was made or reset
	public var isCaughtUp: Bool {
		seeds == nil && unconfirmed == nil
	}

	public subscript(kind: SyncKind, id: String) -> SyncRecord? {
		records[SyncRecord.Key(kind: kind, id: id)]
	}

	/// Records with a pending value over `SyncLimit.valueBytes`. They stay on this device, so the app can say so.
	public var oversized: Set<SyncRecord.Key> {
		Set(pending.values.filter { change in
			change.fields.values.contains { $0.value.byteCount > SyncLimit.valueBytes }
		}.map(\.key))
	}

	// MARK: - Local changes

	/// Records the current values of a record's fields. Only the fields whose value actually differs get a stamp,
	/// so handing over the whole record after every change costs a comparison, and writing back a remote change
	/// then reporting it here does nothing. Fields left out are left alone.
	///
	/// Every field changed by one call shares one stamp. Returns whether anything changed.
	@discardableResult
	public mutating func recordLocal(kind: SyncKind, id: String, fields: [String: JSONValue], at deviceNow: Date = .now) -> Bool {
		// Only the server writes these, so a device's copy of one is never an edit
		guard !kind.isServerOwned else { return false }
		let key = SyncRecord.Key(kind: kind, id: id)
		let record = records[key]
		var edited: [String: JSONValue] = [:]
		var seeded: [String: JSONValue] = [:]
		for (name, value) in fields where record?.fields[name]?.value != value {
			if seeds != nil, record?.fields[name] == nil {
				if seeds?[key]?.fields[name]?.value != value {
					seeded[name] = value
				}
			} else {
				edited[name] = value
			}
		}
		guard !edited.isEmpty || !seeded.isEmpty else { return false }

		let stamp = clock.tick(at: deviceNow)
		if !seeded.isEmpty {
			var seed = seeds?[key] ?? SyncRecord(kind: kind, id: id)
			for (name, value) in seeded {
				seed.fields[name] = SyncField(value: value, stamp: stamp)
			}
			seeds?[key] = seed
		}
		if !edited.isEmpty {
			var record = record ?? SyncRecord(kind: kind, id: id)
			var change = pending[key] ?? SyncChange(kind: kind, id: id, fields: [:])
			for (name, value) in edited {
				// An edit not sent yet keeps the base it started from
				if change.fields[name] == nil {
					change.bases[name] = record.fields[name]?.stamp
				}
				let field = SyncField(value: value, stamp: stamp)
				record.fields[name] = field
				change.fields[name] = field
			}
			records[key] = record
			pending[key] = change
		}
		return true
	}

	// MARK: - Requests

	/// Pending changes in `pushesBefore` order, up to a body comfortably under `SyncLimit.requestBytes`.
	///
	/// Holds every change back until the clock has a server time, since its stamps could be refused. Leaves out
	/// fields over `SyncLimit.valueBytes`, which would be refused forever (see `oversized`).
	public func makeRequest(limit: Int? = nil) -> SyncRequest {
		var changes: [SyncChange] = []
		var bytes = 0
		for change in sendable() {
			let size = (try? JSONEncoder().encode(change).count) ?? 0
			if !changes.isEmpty, bytes + size > SyncLimit.requestBytes * 3 / 4 {
				break
			}
			changes.append(change)
			bytes += size
		}
		return SyncRequest(cursor: cursor, changes: changes, limit: limit)
	}

	func sendable() -> [SyncChange] {
		guard clock.offset != nil else { return [] }
		return pending.values.sorted { Self.pushesBefore($0.key, $1.key) }.compactMap { change in
			var change = change
			change.fields = change.fields.filter { $0.value.value.byteCount <= SyncLimit.valueBytes }
			change.bases = change.bases.filter { change.fields[$0.key] != nil }
			return change.fields.isEmpty ? nil : change
		}
	}

	/// A board before its statements, which key order gives, and a statement before its links, which it doesn't.
	/// Another device can pull part way through a big push, and it deletes a link whose statement looks gone.
	static func pushesBefore(_ a: SyncRecord.Key, _ b: SyncRecord.Key) -> Bool {
		if (a.kind == .link) != (b.kind == .link) {
			return b.kind == .link
		}
		return a < b
	}

	// MARK: - Starting over

	/// For signing out and `syncResetRequired`: forgets the cursor but keeps what's merged and pending, so the next
	/// sync pulls everything, merges it by stamp as usual, and pushes back what the server doesn't have.
	/// Signing in again, to any account, then loses nothing.
	public mutating func reset() {
		cursor = nil
		unconfirmed = Set(records.keys).union(unconfirmed ?? [])
	}

	/// Removes records outright, with nothing left to push or merge, for signing out of a board that isn't yours.
	/// Unlike a tombstone, this says nothing to the server.
	public mutating func forget(_ keys: Set<SyncRecord.Key>) {
		for key in keys {
			records[key] = nil
			pending[key] = nil
			seeds?[key] = nil
			unconfirmed?.remove(key)
		}
	}

	/// For when the server refuses a stamp as too far ahead: the next sync measures the clock before pushing,
	/// and `apply` then restamps what was refused
	public mutating func recalibrate() {
		clock.forgetOffset()
	}
}

/// What applying a sync response changed
public struct SyncApplied: Sendable, Hashable {
	/// Every record whose merged state changed, for the app to write back. Includes tombstones (`isDeleted`),
	/// and kinds or fields this version doesn't know, which the app skips. A stamp-only change counts too,
	/// since `isDeleted` and `newestStamp` follow the stamps. Records the server refused are here as well, so what the
	/// app shows goes back to what the server has, or goes away if that's nothing.
	public var changed: [SyncRecord]

	/// The losing sides of concurrent edits this device made, found by the server or by this replica.
	/// Each reaches exactly one device. The app copies a board's lost `content` into a new board and ignores the rest.
	public var superseded: [SupersededField]

	/// Sync again straight away: there's more to pull, or changes this request held back
	public var syncAgain: Bool

	public init(changed: [SyncRecord], superseded: [SupersededField], syncAgain: Bool) {
		self.changed = changed
		self.superseded = superseded
		self.syncAgain = syncAgain
	}
}

// MARK: - Coding

/// Saved as plain lists, since JSON can't key an object by a struct
extension SyncReplica: Codable {
	enum CodingKeys: String, CodingKey {
		case records, pending, cursor, clock, seeds, unconfirmed
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let records = try container.decode([SyncRecord].self, forKey: .records)
		let pending = try container.decode([SyncChange].self, forKey: .pending)
		let seeds = try container.decodeIfPresent([SyncRecord].self, forKey: .seeds)
		try self.init(
			records: Dictionary(records.map { ($0.key, $0) }) { _, last in last },
			pending: Dictionary(pending.map { ($0.key, $0) }) { _, last in last },
			cursor: container.decodeIfPresent(Int.self, forKey: .cursor),
			clock: container.decode(SyncClock.self, forKey: .clock),
			seeds: seeds.map { seeds in Dictionary(seeds.map { ($0.key, $0) }) { _, last in last } },
			unconfirmed: container.decodeIfPresent([SyncRecord.Key].self, forKey: .unconfirmed).map(Set.init)
		)
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(records.values.sorted { $0.key < $1.key }, forKey: .records)
		try container.encode(pending.values.sorted { $0.key < $1.key }, forKey: .pending)
		try container.encodeIfPresent(cursor, forKey: .cursor)
		try container.encode(clock, forKey: .clock)
		try container.encodeIfPresent(seeds?.values.sorted { $0.key < $1.key }, forKey: .seeds)
		try container.encodeIfPresent(unconfirmed?.sorted(), forKey: .unconfirmed)
	}
}
