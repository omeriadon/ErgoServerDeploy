//
//  SyncRecord.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import Foundation

/// Everything synced is a record: a kind, an id, and named fields that each merge on their own.
/// The server and the app merge with the same `merge`, so every copy ends up the same.
public struct SyncRecord: Codable, Sendable, Hashable {
	public struct Key: Codable, Sendable, Hashable, Comparable {
		public var kind: SyncKind
		public var id: String

		public init(kind: SyncKind, id: String) {
			self.kind = kind
			self.id = id
		}

		public static func < (a: Key, b: Key) -> Bool {
			(a.kind.rawValue, a.id) < (b.kind.rawValue, b.id)
		}
	}

	public var kind: SyncKind
	public var id: String
	public var fields: [String: SyncField]

	public init(kind: SyncKind, id: String, fields: [String: SyncField] = [:]) {
		self.kind = kind
		self.id = id
		self.fields = fields
	}

	public var key: Key {
		Key(kind: kind, id: id)
	}

	// MARK: - Merging

	/// Keeps the newer field for each name. Commutative, associative and idempotent, so copies agree
	/// whatever order changes arrive in. Both must be the same record; `a`'s kind and id are kept.
	public static func merge(_ a: SyncRecord, _ b: SyncRecord) -> SyncRecord {
		var merged = a
		merged.merge(b.fields)
		return merged
	}

	public mutating func merge(_ other: [String: SyncField]) {
		fields.merge(other, uniquingKeysWith: SyncField.newer)
	}

	// MARK: - Derived

	/// A tombstone: `deleted` is `true` and newer than every other field. Typing on another device after a delete
	/// is newer, so it brings the record back, and undoing a delete is just a newer `false`.
	public var isDeleted: Bool {
		guard let deleted = fields[SyncFieldName.deleted], deleted.value == .bool(true) else {
			return false
		}
		return fields.allSatisfy { name, field in name == SyncFieldName.deleted || field.stamp < deleted.stamp }
	}

	/// When the record last changed on any device, so every device sorts boards the same way
	public var newestStamp: SyncStamp? {
		fields.values.lazy.map(\.stamp).max()
	}
}

// MARK: - Pushes

public extension SyncRecord {
	/// The server's side of a push: merges `change` in, and returns the losing side of every concurrent field.
	///
	/// A field is concurrent when what's stored is neither the edit's base nor the edit itself, so a device that
	/// edited from an older value didn't see what it overwrites. Equal values aren't a conflict.
	mutating func apply(_ change: SyncChange) -> [SupersededField] {
		var superseded: [SupersededField] = []
		for (name, incoming) in change.fields {
			guard let stored = fields[name] else {
				fields[name] = incoming
				continue
			}

			let kept = SyncField.newer(stored, incoming)
			fields[name] = kept
			let isConcurrent = stored.stamp != change.bases[name] && stored.stamp != incoming.stamp
			if isConcurrent, stored.value != incoming.value {
				superseded.append(SupersededField(kind: kind, id: id, field: name, lost: kept == stored ? incoming : stored))
			}
		}
		return superseded
	}
}
