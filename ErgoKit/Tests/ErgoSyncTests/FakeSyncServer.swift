//
//  FakeSyncServer.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoSync
import Foundation
import Testing

/// `POST v1/sync` in memory, with the same merge and the checks replicas can trip over
struct FakeSyncServer {
	enum Refusal: Error, Equatable {
		case syncResetRequired
		case futureStamp
	}

	struct Row: Equatable {
		var record: SyncRecord
		var seq: Int
	}

	var rows: [SyncRecord.Key: Row] = [:]
	var seq = 0
	var prunedThrough = 0

	/// The server's clock, in milliseconds since 1970
	var now: Int64 = 1_793_836_800_000

	var records: [SyncRecord.Key: SyncRecord] {
		rows.mapValues(\.record)
	}

	/// Applies the push, then returns a board of everything after the cursor, like `SyncService.apply`
	mutating func sync(_ request: SyncRequest) throws(Refusal) -> SyncResponse {
		if let cursor = request.cursor, cursor < prunedThrough {
			throw .syncResetRequired
		}
		for change in request.changes {
			if change.fields.values.contains(where: { $0.stamp.time > now + SyncLimit.futureStamp }) {
				throw .futureStamp
			}
		}

		var superseded: [SupersededField] = []
		for change in request.changes {
			let stored = rows[change.key]?.record
			var record = stored ?? change.record.withoutFields
			superseded += record.apply(change)
			if record != stored {
				seq += 1
				rows[change.key] = Row(record: record, seq: seq)
			}
		}

		let after = rows.values.filter { $0.seq > request.cursor ?? 0 }.sorted { $0.seq < $1.seq }
		let limit = min(request.limit ?? SyncLimit.defaultRecords, SyncLimit.maxRecords)
		let board = after.prefix(limit)
		let more = after.count > limit
		return SyncResponse(
			cursor: more ? board.last?.seq ?? seq : seq,
			changes: board.map(\.record),
			more: more,
			superseded: superseded,
			serverTime: Date(milliseconds: now)
		)
	}

	/// Drops every tombstone, as the daily prune does once they're 90 days old, and the statements and links of
	/// every board it drops. Those don't count towards `prunedThrough`, since they say nothing a client needs to hear.
	mutating func prune() {
		var boards: Set<String> = []
		for (key, row) in rows where row.record.isDeleted {
			rows[key] = nil
			prunedThrough = max(prunedThrough, row.seq)
			if key.kind == .board {
				boards.insert(key.id)
			}
		}
		for (key, row) in rows where row.record.owningBoard.map(boards.contains) == true {
			rows[key] = nil
		}
	}
}

// MARK: - Devices

/// A replica with its own clock, standing in for the app on one device
struct FakeDevice {
	var replica: SyncReplica

	/// How far this device's clock is from the server's, in milliseconds
	var skew: Int64

	/// Every superseded value this device was handed, which the app would copy into a new board
	var superseded: [SupersededField] = []

	init(_ device: String, skew: Int64 = 0) {
		replica = SyncReplica(device: device)
		self.skew = skew
	}

	func now(_ server: FakeSyncServer) -> Date {
		Date(milliseconds: server.now + skew)
	}

	@discardableResult
	mutating func edit(_ kind: SyncKind, _ id: String, _ fields: [String: JSONValue], _ server: FakeSyncServer) -> Bool {
		replica.recordLocal(kind: kind, id: id, fields: fields, at: now(server))
	}

	/// A request the server has answered but the device hasn't heard back from, so edits can happen in between
	var inFlight: (request: SyncRequest, response: SyncResponse)?

	/// One round trip. A lost reply means the server applied the push but the device never heard back.
	@discardableResult
	mutating func sync(with server: inout FakeSyncServer, limit: Int? = nil, losingReply: Bool = false) -> SyncApplied? {
		send(to: &server, limit: limit)
		return losingReply ? loseReply() : receive(server)
	}

	mutating func send(to server: inout FakeSyncServer, limit: Int? = nil) {
		let request = replica.makeRequest(limit: limit)
		do {
			inFlight = try (request, server.sync(request))
		} catch .syncResetRequired {
			replica.reset()
		} catch {
			replica.recalibrate()
		}
	}

	mutating func receive(_ server: FakeSyncServer) -> SyncApplied? {
		guard let (request, response) = inFlight else { return nil }
		inFlight = nil
		let applied = replica.apply(response, sent: request, at: now(server))
		superseded += applied.superseded
		return applied
	}

	mutating func loseReply() -> SyncApplied? {
		inFlight = nil
		return nil
	}

	/// Syncs until there's nothing left to push or pull, as the app does when `syncAgain` is set
	mutating func syncUntilDone(with server: inout FakeSyncServer, limit: Int? = nil) {
		_ = receive(server)
		for _ in 0 ..< 100 {
			if let applied = sync(with: &server, limit: limit), !applied.syncAgain {
				return
			}
		}
		Issue.record("Expected sync to settle within 100 round trips")
	}
}

// MARK: - Helpers

extension SyncRecord {
	var withoutFields: SyncRecord {
		SyncRecord(kind: kind, id: id)
	}

	var values: [String: JSONValue] {
		fields.mapValues(\.value)
	}
}

extension Date {
	init(milliseconds: Int64) {
		self.init(timeIntervalSince1970: Double(milliseconds) / 1000)
	}
}

/// SplitMix64, so a failing seed fails the same way every run
struct SeededRandom: RandomNumberGenerator {
	var state: UInt64

	init(seed: UInt64) {
		state = seed
	}

	mutating func next() -> UInt64 {
		state &+= 0x9E37_79B9_7F4A_7C15
		var z = state
		z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
		z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
		return z ^ (z >> 31)
	}
}
