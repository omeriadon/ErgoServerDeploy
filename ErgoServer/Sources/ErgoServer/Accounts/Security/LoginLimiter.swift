//
//  LoginLimiter.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import Crypto
import Foundation
import Synchronization

/// Slows guessing passwords: a few failures per address and a few per email, each within a window. Both,
/// because one address can try many emails and many addresses can try one email. Kept in memory, so a restart
/// forgets, which is fine for slowing down a script.
///
/// An email's failures count whether or not it has an account, so being blocked says nothing about which emails exist.
/// The price is that anyone can use up an email's failures to keep its owner out for one window.
final class LoginLimiter: Sendable {
	let limit: Int
	let window: TimeInterval
	private let recent = Mutex<[String: [Date]]>([:])

	init(limit: Int, window: TimeInterval = 15 * 60) {
		self.limit = limit
		self.window = window
	}

	// MARK: - Counting

	/// How long until a try from `address` at `email` would be allowed, or nil if it is now
	func wait(address: String, email: String, now: Date = .now) -> TimeInterval? {
		recent.withLock { recent in
			sweep(&recent, now: now)
			let waits = [Self.key(address: address), Self.key(email: email)].compactMap { key -> TimeInterval? in
				let times = recent[key, default: []]
				guard times.count >= limit else { return nil }
				return times[times.count - limit].addingTimeInterval(window).timeIntervalSince(now)
			}
			return waits.max()
		}
	}

	func fail(address: String, email: String, now: Date = .now) {
		recent.withLock { recent in
			sweep(&recent, now: now)
			for key in [Self.key(address: address), Self.key(email: email)] {
				recent[key, default: []].append(now)
			}
		}
	}

	/// Only the email's, so an address can't reset its own count by logging in to an account of its own
	func succeed(email: String) {
		recent.withLock { $0[Self.key(email: email)] = nil }
	}

	/// Forget everyone whose window has passed, so the table can't grow forever
	private func sweep(_ recent: inout [String: [Date]], now: Date) {
		recent = recent.compactMapValues { times in
			let kept = times.filter { now.timeIntervalSince($0) < window }
			return kept.isEmpty ? nil : kept
		}
	}

	// MARK: - Keys

	private static func key(address: String) -> String {
		"address:" + address
	}

	/// Hashed, so the table doesn't hold the emails
	private static func key(email: String) -> String {
		"email:" + SHA256.hash(data: Data(email.utf8)).map { String(format: "%02x", $0) }.joined()
	}

	// MARK: - Wording

	/// "12 minutes", rounded up so waiting that long always works
	static func describe(wait: TimeInterval) -> String {
		let seconds = max(1, Int(wait.rounded(.up)))
		guard seconds >= 60 else { return seconds == 1 ? "1 second" : "\(seconds) seconds" }
		let minutes = (seconds + 59) / 60
		return minutes == 1 ? "1 minute" : "\(minutes) minutes"
	}
}
