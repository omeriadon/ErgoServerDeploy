//
//  SyncScheduleTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 6/11/2026.
//

import ErgoSync
import Testing

struct SyncScheduleTests {
	/// A schedule that is running, with nothing queued
	static func running() -> SyncSchedule {
		var schedule = SyncSchedule()
		_ = schedule.apply(.requested)
		return schedule
	}

	/// A schedule backing off after `failures` failures
	static func backingOff(failures: Int = 1) -> SyncSchedule {
		var schedule = SyncSchedule()
		_ = schedule.apply(.requested)
		for attempt in 0 ..< failures {
			_ = schedule.apply(.failed)
			// Retried, except after the last
			if attempt < failures - 1 {
				_ = schedule.apply(.timerFired)
			}
		}
		return schedule
	}

	// MARK: - Local change

	@Test func aLocalChangeFromIdleStartsThePause() {
		var schedule = SyncSchedule()
		#expect(schedule.apply(.localChange) == .startTimer(.seconds(2)))
		#expect(schedule.phase == .debouncing)
	}

	@Test func aLocalChangeWhileDebouncingRestartsThePause() {
		var schedule = SyncSchedule()
		_ = schedule.apply(.localChange)
		#expect(schedule.apply(.localChange) == .startTimer(.seconds(2)))
		#expect(schedule.phase == .debouncing)
	}

	@Test func aLocalChangeWhileRunningWaitsAFreshPauseAfterwards() {
		var schedule = Self.running()
		#expect(schedule.apply(.localChange) == .nothing)
		#expect(schedule.phase == .running(.afterPause))
		#expect(schedule.apply(.succeeded) == .startTimer(.seconds(2)))
		#expect(schedule.phase == .debouncing)
	}

	@Test func nextNeverDowngradesFromNow() {
		var schedule = Self.running()
		_ = schedule.apply(.requested)
		#expect(schedule.phase == .running(.now))
		#expect(schedule.apply(.localChange) == .nothing)
		#expect(schedule.phase == .running(.now))
	}

	@Test func aLocalChangeDuringBackoffNeitherExtendsNorAddsToIt() {
		var schedule = Self.backingOff()
		#expect(schedule.apply(.localChange) == .nothing)
		#expect(schedule.phase == .backingOff)
		#expect(schedule.failures == 1)
	}

	// MARK: - Requests

	@Test func aRequestRunsFromIdleAndDebouncing() {
		var idle = SyncSchedule()
		#expect(idle.apply(.requested) == .run)
		#expect(idle.phase == .running(.nothing))

		var debouncing = SyncSchedule()
		_ = debouncing.apply(.localChange)
		#expect(debouncing.apply(.requested) == .run)
		#expect(debouncing.phase == .running(.nothing))
	}

	@Test func aRequestWhileRunningRunsAgainAfterwards() {
		var schedule = Self.running()
		#expect(schedule.apply(.requested) == .nothing)
		#expect(schedule.phase == .running(.now))
		#expect(schedule.apply(.succeeded) == .run)
		#expect(schedule.phase == .running(.nothing))
	}

	@Test func aRequestDuringBackoffWaits() {
		var schedule = Self.backingOff()
		#expect(schedule.apply(.requested) == .nothing)
		#expect(schedule.phase == .backingOff)
		#expect(schedule.failures == 1)
	}

	// MARK: - Request now

	@Test func requestingNowRunsFromIdleAndDebouncing() {
		var idle = SyncSchedule()
		#expect(idle.apply(.requestedNow) == .run)

		var debouncing = SyncSchedule()
		_ = debouncing.apply(.localChange)
		#expect(debouncing.apply(.requestedNow) == .run)
		#expect(debouncing.phase == .running(.nothing))
	}

	@Test func requestingNowWhileRunningRunsAgainAfterwards() {
		var schedule = Self.running()
		#expect(schedule.apply(.requestedNow) == .nothing)
		#expect(schedule.phase == .running(.now))
	}

	@Test func requestingNowInterruptsBackoffAndClearsFailures() {
		var schedule = Self.backingOff(failures: 3)
		#expect(schedule.apply(.requestedNow) == .run)
		#expect(schedule.phase == .running(.nothing))
		#expect(schedule.failures == 0)
	}

	// MARK: - Timer

	@Test func theTimerRunsFromDebouncingAndBackoff() {
		var debouncing = SyncSchedule()
		_ = debouncing.apply(.localChange)
		#expect(debouncing.apply(.timerFired) == .run)
		#expect(debouncing.phase == .running(.nothing))

		var backingOff = Self.backingOff()
		#expect(backingOff.apply(.timerFired) == .run)
		#expect(backingOff.phase == .running(.nothing))
		#expect(backingOff.failures == 1)
	}

	@Test func theTimerIsIgnoredFromIdleAndRunning() {
		var idle = SyncSchedule()
		#expect(idle.apply(.timerFired) == .nothing)
		#expect(idle.phase == .idle)

		var running = Self.running()
		#expect(running.apply(.timerFired) == .nothing)
		#expect(running.phase == .running(.nothing))
	}

	// MARK: - Success

	@Test func successFollowsNext() {
		var nothing = Self.running()
		#expect(nothing.apply(.succeeded) == .nothing)
		#expect(nothing.phase == .idle)
	}

	@Test func successIsIgnoredOutsideRunning() {
		var idle = SyncSchedule()
		#expect(idle.apply(.succeeded) == .nothing)
		#expect(idle.phase == .idle)

		var debouncing = SyncSchedule()
		_ = debouncing.apply(.localChange)
		#expect(debouncing.apply(.succeeded) == .nothing)
		#expect(debouncing.phase == .debouncing)

		var backingOff = Self.backingOff()
		#expect(backingOff.apply(.succeeded) == .nothing)
		#expect(backingOff.phase == .backingOff)
		#expect(backingOff.failures == 1)
	}

	@Test func successResetsFailuresSoTheNextFailureBacksOffTwoSeconds() {
		var schedule = Self.backingOff(failures: 3)
		#expect(schedule.failures == 3)
		_ = schedule.apply(.timerFired)
		_ = schedule.apply(.succeeded)
		#expect(schedule.failures == 0)

		_ = schedule.apply(.requested)
		#expect(schedule.apply(.failed) == .startTimer(.seconds(2)))
		#expect(schedule.failures == 1)
	}

	// MARK: - Failure

	@Test func failureBacksOffAndDropsNext() {
		var schedule = Self.running()
		_ = schedule.apply(.requested)
		#expect(schedule.apply(.failed) == .startTimer(.seconds(2)))
		#expect(schedule.phase == .backingOff)
		#expect(schedule.failures == 1)

		// Nothing left over from before the failure
		#expect(schedule.apply(.timerFired) == .run)
		#expect(schedule.apply(.succeeded) == .nothing)
		#expect(schedule.phase == .idle)
	}

	@Test func failuresBackOffLonger() {
		var schedule = SyncSchedule()
		var delays: [Duration] = []
		_ = schedule.apply(.requested)
		for _ in 0 ..< 3 {
			if case let .startTimer(delay) = schedule.apply(.failed) {
				delays.append(delay)
			}
			_ = schedule.apply(.timerFired)
		}
		#expect(delays == [.seconds(2), .seconds(4), .seconds(8)])
	}

	@Test func failureIsIgnoredOutsideRunning() {
		var idle = SyncSchedule()
		#expect(idle.apply(.failed) == .nothing)
		#expect(idle.failures == 0)

		var backingOff = Self.backingOff()
		#expect(backingOff.apply(.failed) == .nothing)
		#expect(backingOff.failures == 1)
	}

	@Test func backoffDoublesUpToFiveMinutes() {
		#expect(SyncSchedule.backoff(0) == .seconds(2))
		#expect(SyncSchedule.backoff(1) == .seconds(2))
		#expect(SyncSchedule.backoff(2) == .seconds(4))
		#expect(SyncSchedule.backoff(3) == .seconds(8))
		#expect(SyncSchedule.backoff(7) == .seconds(128))
		#expect(SyncSchedule.backoff(8) == .seconds(256))
		#expect(SyncSchedule.backoff(9) == .seconds(300))
		#expect(SyncSchedule.backoff(100) == .seconds(300))
	}

	// MARK: - Stop

	@Test func stopFromEveryPhaseGoesIdleWithNoFailures() {
		let idle = SyncSchedule()
		var debouncing = SyncSchedule()
		_ = debouncing.apply(.localChange)
		var running = Self.running()
		_ = running.apply(.requested)
		let backingOff = Self.backingOff(failures: 2)

		for var schedule in [idle, debouncing, running, backingOff] {
			#expect(schedule.apply(.stopped) == .cancelTimer)
			#expect(schedule.phase == .idle)
			#expect(schedule.failures == 0)
		}
	}
}
