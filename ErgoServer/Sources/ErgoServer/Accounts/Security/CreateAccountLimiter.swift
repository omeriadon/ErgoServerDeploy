//
//  CreateAccountLimiter.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import Foundation
import Synchronization

/// A few of something per address per window, such as new accounts per hour. Kept in memory, so a restart forgets, which is fine for slowing down a script.
final class CreateAccountLimiter: Sendable {
	let limit: Int
	let window: TimeInterval
	private let recent = Mutex<[String: [Date]]>([:])

	init(limit: Int, window: TimeInterval = 60 * 60) {
		self.limit = limit
		self.window = window
	}

	/// Counts this one if it's allowed
	func allow(_ address: String, now: Date = .now) -> Bool {
		recent.withLock { recent in
			// Forget everyone whose window has passed, so the table can't grow forever
			recent = recent.compactMapValues { times in
				let kept = times.filter { now.timeIntervalSince($0) < window }
				return kept.isEmpty ? nil : kept
			}

			guard recent[address, default: []].count < limit else { return false }
			recent[address, default: []].append(now)
			return true
		}
	}
}
