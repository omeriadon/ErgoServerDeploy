//
//  PushThrottle.swift
//  ErgoServer
//
//  Created by Adon Omeri on 7/11/2026.
//

import Foundation
import Synchronization

/// How often someone hears about edits, so a busy board doesn't buzz their phone with every box moved. Only edits go
/// through here: joining, role changes and removals always alert. In memory like `SyncLimits`, so a restart forgets.
final class PushThrottle: Sendable {
	enum Decision: Sendable, Equatable {
		case alert, silent, nothing
	}

	/// At most one alert per board and person in this long
	static let alertWindow: TimeInterval = 15 * 60

	/// Otherwise at most one silent push per account in this long
	static let silentWindow: TimeInterval = 60

	private struct Recent {
		var alerts: [String: Date] = [:]
		var silents: [UUID: Date] = [:]
		var swept = Date.distantPast
	}

	private let recent = Mutex<Recent>(Recent())

	/// Counts this one if it's sent
	func decide(board: String, account: UUID, now: Date = .now) -> Decision {
		recent.withLock { recent in
			// Forget the quiet ones, at most once a minute, so the tables can't grow forever
			if now.timeIntervalSince(recent.swept) > Self.silentWindow {
				recent.alerts = recent.alerts.filter { now.timeIntervalSince($0.value) < Self.alertWindow }
				recent.silents = recent.silents.filter { now.timeIntervalSince($0.value) < Self.silentWindow }
				recent.swept = now
			}

			let person = "\(board)/\(account.uuidString)"
			if recent.alerts[person].map({ now.timeIntervalSince($0) >= Self.alertWindow }) ?? true {
				recent.alerts[person] = now
				return .alert
			}
			if recent.silents[account].map({ now.timeIntervalSince($0) >= Self.silentWindow }) ?? true {
				recent.silents[account] = now
				return .silent
			}
			return .nothing
		}
	}
}
