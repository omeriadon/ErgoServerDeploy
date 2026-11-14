//
//  LogThrottle.swift
//  ErgoServer
//
//  Created by Adon Omeri on 10/11/2026.
//

import Foundation
import Synchronization

/// Keeps a line that can repeat (a dead token that the app keeps retrying, a wrong password tried a thousand times) to one
/// a minute, and says how many it left out. In memory, so a restart forgets.
final class LogThrottle: Sendable {
	let window: TimeInterval
	private let entries = Mutex<[String: Entry]>([:])

	private struct Entry {
		var said: Date
		var leftOut = 0
	}

	init(window: TimeInterval = 60) {
		self.window = window
	}

	/// Nil when `key` was said within the window, and is counted instead. Otherwise the number left out since it was last said.
	func allow(_ key: String, now: Date = .now) -> Int? {
		entries.withLock { entries -> Int? in
			if var entry = entries[key], now.timeIntervalSince(entry.said) < window {
				entry.leftOut += 1
				entries[key] = entry
				return nil
			}

			let leftOut = entries[key]?.leftOut ?? 0
			entries[key] = Entry(said: now)
			// The keys are routes and codes, so there are few, but nothing outside the server's own words may grow this for ever
			if entries.count > 500 {
				entries = entries.filter { now.timeIntervalSince($0.value.said) < window }
			}
			return leftOut
		}
	}
}
