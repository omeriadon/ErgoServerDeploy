//
//  SyncReplica+Responses.swift
//  Ergo
//
//  Created by Adon Omeri on 8/11/2026.
//

import Foundation

extension SyncReplica {
	// MARK: - Responses

	/// Merges what the server sent, acknowledges what `sent` pushed, takes back what it refused, and corrects the clock.
	///
	/// `sent` must be the request this answers. A response to a request made before a `reset` still merges
	/// (merging is always safe) but doesn't move the cursor, so the reset's full pull still happens.
	public mutating func apply(_ response: SyncResponse, sent: SyncRequest, at deviceNow: Date = .now) -> SyncApplied {
		let isCurrent = sent.cursor == cursor
		var sentStamps: [SyncRecord.Key: [String: SyncStamp]] = [:]
		for change in sent.changes {
			sentStamps[change.key, default: [:]].merge(change.fields.mapValues(\.stamp)) { _, last in last }
		}

		var changed: [SyncRecord.Key] = []
		var superseded: [SupersededField] = []
		var lostHere: [SyncRecord.Key: Set<String>] = [:]
		for incoming in response.changes {
			if let stamp = incoming.newestStamp {
				clock.receive(stamp)
			}
			let key = incoming.key
			unconfirmed?.remove(key)

			let old = records[key]
			let merged = old.map { SyncRecord.merge($0, incoming) } ?? incoming
			if merged != old {
				records[key] = merged
				if !changed.contains(key) {
					changed.append(key)
				}
			}

			// Unsent edits a remote value beat. The server never saw them, so this is the only place they're caught.
			for (name, field) in pending[key]?.fields ?? [:] where merged.fields[name] != field && sentStamps[key]?[name] != field.stamp {
				if merged.fields[name]?.value != field.value {
					superseded.append(SupersededField(kind: key.kind, id: key.id, field: name, lost: field))
					lostHere[key, default: []].insert(name)
				}
				drop(name, of: key)
			}

			// The server's copy is missing something this replica has, after a reset or the server pruning a
			// tombstone. Pushing it back is what makes every copy agree. What only the server writes stays as it is.
			let missing = merged.fields.filter { name, field in incoming.fields[name] != field && pending[key]?.fields[name] == nil }
			if !missing.isEmpty, !key.kind.isServerOwned {
				pending[key, default: SyncChange(kind: key.kind, id: key.id, fields: [:])].fields.merge(missing) { pending, _ in pending }
			}
		}

		acknowledge(sent)

		for field in response.superseded {
			clock.receive(field.lost.stamp)
			// A newer edit of ours grew from this lost one, and that edit is either still pending or reported above
			let isOurs = sentStamps[field.key]?[field.field] == field.lost.stamp
			let grewOn = pending[field.key]?.fields[field.field] != nil || lostHere[field.key]?.contains(field.field) == true
			if !(isOurs && grewOn) {
				superseded.append(field)
			}
		}

		clock.adjust(serverTime: response.serverTime, at: deviceNow)
		for rejected in response.rejected ?? [] {
			if undo(rejected, at: deviceNow), !changed.contains(rejected.key) {
				changed.append(rejected.key)
			}
			// A copy of a refused edit would only be refused too
			superseded.removeAll { $0.key == rejected.key }
		}
		if isCurrent {
			cursor = response.cursor
			if !response.more, !isCaughtUp {
				finishCatchingUp()
			}
		}
		restampFuture(at: deviceNow)
		pruneTombstones(at: deviceNow)

		return SyncApplied(
			changed: changed.compactMap { records[$0] },
			superseded: superseded,
			syncAgain: response.more || !sendable().isEmpty
		)
	}

	mutating func acknowledge(_ sent: SyncRequest) {
		for change in sent.changes {
			guard var waiting = pending[change.key] else { continue }
			for (name, field) in change.fields {
				guard let current = waiting.fields[name] else { continue }
				if current.stamp == field.stamp {
					waiting.fields[name] = nil
					waiting.bases[name] = nil
				} else {
					// Edited again during the request, from what was just sent
					waiting.bases[name] = field.stamp
				}
			}
			pending[change.key] = waiting.fields.isEmpty ? nil : waiting
		}
	}

	mutating func drop(_ name: String, of key: SyncRecord.Key) {
		pending[key]?.fields[name] = nil
		pending[key]?.bases[name] = nil
		if pending[key]?.fields.isEmpty == true {
			pending[key] = nil
		}
	}

	/// Takes back a change the server refused: everything unsent goes too, typing since the request included, and the
	/// record becomes what the server has. Returns whether there's a record for the app to write back.
	mutating func undo(_ rejected: RejectedChange, at deviceNow: Date) -> Bool {
		let key = rejected.key
		pending[key] = nil
		seeds?[key] = nil
		unconfirmed?.remove(key)

		if let current = rejected.current {
			if let stamp = current.newestStamp {
				clock.receive(stamp)
			}
			records[key] = current
			return true
		}
		// The server has nothing, so this is a phantom only this device knows of. The tombstone tells the app to drop it.
		guard records[key] != nil else { return false }
		records[key]?.fields[SyncFieldName.deleted] = SyncField(value: true, stamp: clock.tick(at: deviceNow))
		return true
	}

	/// The full pull is done, so whatever the server didn't have goes up
	mutating func finishCatchingUp() {
		var pushes: [SyncRecord.Key: [String: SyncField]] = [:]
		// In order, since whether a statement or link is ignored depends on the seeds merged before it
		for (key, seed) in (seeds ?? [:]).sorted(by: { Self.pushesBefore($0.key, $1.key) }) where !seed.isDeleted && !isIgnored(seed) && !key.kind.isServerOwned {
			let missing = seed.fields.filter { records[key]?.fields[$0.key] == nil }
			if !missing.isEmpty {
				records[key, default: SyncRecord(kind: key.kind, id: key.id)].merge(missing)
				pushes[key, default: [:]].merge(missing) { a, _ in a }
			}
		}
		for key in unconfirmed ?? [] {
			// The server no longer has it for this account, and only the server can write one
			if key.kind.isServerOwned {
				records[key] = nil
				pending[key] = nil
				continue
			}
			// Ignored records are what the server pruned with their board, so they stay down
			guard let record = records[key], !record.isDeleted, !isIgnored(record) else { continue }
			pushes[key, default: [:]].merge(record.fields) { a, _ in a }
		}
		seeds = nil
		unconfirmed = nil

		for (key, fields) in pushes {
			pending[key, default: SyncChange(kind: key.kind, id: key.id, fields: [:])].fields.merge(fields) { pending, _ in pending }
		}
	}

	/// Stamps made while the device clock was far ahead would be refused, so once the clock is corrected
	/// they're made again. Only unsent ones can be that far ahead, so nothing the server has moves.
	mutating func restampFuture(at deviceNow: Date) {
		let limit = clock.now(deviceNow) + SyncLimit.futureStamp / 2
		guard let last = clock.last, last.time > limit else { return }

		func isFuture(_ key: SyncRecord.Key, _ name: String, _ field: SyncField) -> Bool {
			field.stamp.time > limit && pending[key]?.fields[name]?.stamp == field.stamp
		}

		// The clock goes back only as far as the newest stamp anyone else might have
		var kept: SyncStamp?
		for (key, record) in records {
			for (name, field) in record.fields where !isFuture(key, name, field) {
				kept = max(kept ?? field.stamp, field.stamp)
			}
		}
		clock.rewind(to: kept)
		let stamp = clock.tick(at: deviceNow)

		for (key, change) in pending {
			for (name, field) in change.fields where field.stamp > stamp {
				pending[key]?.fields[name]?.stamp = stamp
				records[key]?.fields[name]?.stamp = stamp
			}
		}
		for (key, seed) in seeds ?? [:] {
			for (name, field) in seed.fields where field.stamp > stamp {
				seeds?[key]?.fields[name]?.stamp = stamp
			}
		}
	}

	/// The server prunes tombstones after `SyncLimit.tombstoneDays`, so they're dropped here too, rather than keeping
	/// deleted boards' text on the device forever
	///
	/// A pruned board takes its statements and links with it, like on the server. Without that a reset would push
	/// them back up as orphans.
	mutating func pruneTombstones(at deviceNow: Date) {
		let cutoff = clock.now(deviceNow) - Int64(SyncLimit.tombstoneDays) * 86_400_000
		func isOld(_ key: SyncRecord.Key, _ record: SyncRecord) -> Bool {
			guard record.isDeleted, pending[key] == nil, let deleted = record.fields[SyncFieldName.deleted] else { return false }
			return deleted.stamp.time < cutoff
		}

		let boards = Set(records.filter { key, record in key.kind == .board && isOld(key, record) }.keys.map(\.id))
		records = records.filter { key, record in
			if isOld(key, record) {
				return false
			}
			guard !boards.isEmpty, pending[key] == nil, let board = record.owningBoard else { return true }
			return !boards.contains(board)
		}
	}
}
