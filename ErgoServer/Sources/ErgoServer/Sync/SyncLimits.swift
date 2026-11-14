//
//  SyncLimits.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoProtocol
import Foundation
import Synchronization

/// What a sync request may hold, and how often an account may send one. The numbers are `SyncLimit`'s,
/// shared with the app so it never builds a request that's refused forever.
final class SyncLimits: Sendable {
	let requestsPerMinute: Int
	private let recent = Mutex<Recent>(Recent())

	private struct Recent {
		var times: [UUID: [Date]] = [:]
		var swept = Date.distantPast
	}

	init(requestsPerMinute: Int = SyncLimit.requestsPerMinute) {
		self.requestsPerMinute = requestsPerMinute
	}

	// MARK: - Rate

	/// Counts this one if it's allowed. Kept in memory, so a restart forgets, which is fine for stopping a loop.
	func allow(_ account: UUID, now: Date = .now) -> Bool {
		recent.withLock { recent in
			// Forget accounts that went quiet, at most once a minute so a sync never pays for every account
			if now.timeIntervalSince(recent.swept) > 60 {
				recent.times = recent.times.filter { $0.value.last.map { now.timeIntervalSince($0) < 60 } ?? false }
				recent.swept = now
			}

			let kept = recent.times[account, default: []].filter { now.timeIntervalSince($0) < 60 }
			guard kept.count < requestsPerMinute else {
				recent.times[account] = kept
				return false
			}
			recent.times[account] = kept + [now]
			return true
		}
	}

	// MARK: - Requests

	/// Everything that can be checked without the database. Throws a `ServiceError` worded for the user.
	static func check(_ request: SyncRequest, now: Date = .now) throws {
		if let cursor = request.cursor, cursor < 0 {
			throw ServiceError(code: .invalidRequest, message: "Expected a cursor of at least 0, found \(cursor)")
		}
		if let limit = request.limit, limit < 1 {
			throw ServiceError(code: .invalidRequest, message: "Expected a limit of at least 1, found \(limit)")
		}

		let latest = milliseconds(now) + SyncLimit.futureStamp
		for change in request.changes {
			try check(kind: change.kind, id: change.id)
			for (name, field) in change.fields {
				guard change.kind.fieldNames.contains(name) else {
					throw ServiceError(code: .invalidRequest, message: "Unknown field '\(shortened(name))' in a \(change.kind.rawValue) record")
				}
				let bytes = field.value.byteCount
				guard bytes <= SyncLimit.valueBytes else {
					throw ServiceError(
						code: .tooLarge,
						message: "Expected a \(change.kind.rawValue) under \(kilobytes(SyncLimit.valueBytes)) KB, found \(kilobytes(bytes)) KB"
					)
				}
				guard field.stamp.time <= latest else {
					let minutes = (field.stamp.time - milliseconds(now) + 59999) / 60000
					throw ServiceError(
						code: .invalidRequest,
						message: "Expected a time within \(SyncLimit.futureStamp / 60000) minutes of the server, found \(minutes) minutes ahead"
					)
				}
			}
		}
	}

	private static func check(kind: SyncKind, id: String) throws {
		guard SyncKind.known.contains(kind) else {
			let known = SyncKind.known.map { "'\($0.rawValue)'" }
			let list = known.dropLast().joined(separator: ", ") + " or " + (known.last ?? "")
			throw ServiceError(code: .invalidRequest, message: "Unknown record kind '\(shortened(kind.rawValue))', expected \(list)")
		}
		guard kind.isValid(id: id) else {
			let message = switch kind {
				case .board, .statement, .link, .scratchpad, .source: "Expected a \(kind.rawValue) id to be an uppercase UUID, found '\(shortened(id))'"
				case .setting: "Unknown setting '\(shortened(id))'"
				default: "Expected a \(kind.rawValue) id of 1 to 256 bytes, found \(id.utf8.count)"
			}
			throw ServiceError(code: .invalidRequest, message: message)
		}
	}

	// MARK: - Formatting

	private static func milliseconds(_ date: Date) -> Int64 {
		Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
	}

	/// Rounded up, so a value just over the limit never reads as equal to it
	private static func kilobytes(_ bytes: Int) -> Int {
		(bytes + 1023) / 1024
	}

	/// Whatever the client sent, short enough to show
	private static func shortened(_ text: String) -> String {
		text.count > 64 ? text.prefix(64) + "…" : text
	}
}
