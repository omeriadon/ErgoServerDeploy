//
//  SyncSchedule.swift
//  ErgoKit
//
//  Created by Adon Omeri on 6/11/2026.
//

import Foundation

/// When sync runs: a pure state machine with no tasks and no clocks. The controller sends it events and does
/// what it answers, so every rule about debouncing, queueing and backing off is here and tested.
public struct SyncSchedule: Sendable, Equatable {
	/// What to do once the running sync ends
	public enum Next: Sendable, Equatable {
		case nothing
		case afterPause
		case now
	}

	public enum Phase: Sendable, Equatable {
		case idle
		/// A local change is waiting for a pause
		case debouncing
		case running(Next)
		/// A sync failed and its retry timer is running
		case backingOff
	}

	public enum Event: Sendable, Equatable {
		case localChange
		/// Waits out a backoff rather than adding to it
		case requested
		/// For when things just got better: starts over from no failures, and interrupts a backoff
		case requestedNow
		case timerFired
		case succeeded
		case failed
		case stopped
	}

	/// What the controller must do. `run` also cancels the timer.
	public enum Action: Sendable, Equatable {
		case nothing
		case startTimer(Duration)
		case cancelTimer
		case run
	}

	/// Local changes wait this long, like `BoardStore`'s save
	public static let pause = Duration.seconds(2)

	public private(set) var phase = Phase.idle
	public private(set) var failures = 0

	public init() {}

	public mutating func apply(_ event: Event) -> Action {
		switch event {
			case .localChange:
				switch phase {
					case .idle, .debouncing:
						phase = .debouncing
						return .startTimer(Self.pause)
					case let .running(next):
						// Never downgrades from now
						phase = .running(next == .now ? .now : .afterPause)
					case .backingOff:
						break
				}
			case .requested:
				switch phase {
					case .idle, .debouncing:
						return start()
					case .running:
						phase = .running(.now)
					case .backingOff:
						break
				}
			case .requestedNow:
				failures = 0
				switch phase {
					case .idle, .debouncing, .backingOff:
						return start()
					case .running:
						phase = .running(.now)
				}
			case .timerFired:
				switch phase {
					case .debouncing, .backingOff:
						return start()
					case .idle, .running:
						break
				}
			case .succeeded:
				guard case let .running(next) = phase else { break }
				failures = 0
				switch next {
					case .nothing:
						phase = .idle
					case .afterPause:
						phase = .debouncing
						return .startTimer(Self.pause)
					case .now:
						return start()
				}
			case .failed:
				guard case .running = phase else { break }
				failures += 1
				phase = .backingOff
				return .startTimer(Self.backoff(failures))
			case .stopped:
				phase = .idle
				failures = 0
				return .cancelTimer
		}
		return .nothing
	}

	private mutating func start() -> Action {
		phase = .running(.nothing)
		return .run
	}

	/// 2, 4, 8 … seconds, up to 5 minutes
	public static func backoff(_ failures: Int) -> Duration {
		.seconds(min(2 << min(max(failures - 1, 0), 8), 300))
	}
}
