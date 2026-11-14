//
//  SyncStampTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoSync
import Foundation
import Testing

struct SyncStampTests {
	static let start = Date(milliseconds: 1_793_836_800_000)

	// MARK: - Order

	@Test func timeThenCounterThenDevice() {
		let stamp = SyncStamp(time: 5, counter: 1, device: "B")
		#expect(stamp < SyncStamp(time: 6, counter: 0, device: "A"))
		#expect(stamp < SyncStamp(time: 5, counter: 2, device: "A"))
		#expect(stamp < SyncStamp(time: 5, counter: 1, device: "C"))
		#expect(stamp > SyncStamp(time: 5, counter: 1, device: "A"))
		#expect(stamp.date == Date(timeIntervalSince1970: 0.005))
	}

	// MARK: - Clock

	@Test func ticksWithinOneMillisecondCount() {
		var clock = SyncClock(device: "A", offset: 0)
		let first = clock.tick(at: Self.start)
		let second = clock.tick(at: Self.start)
		let later = clock.tick(at: Self.start + 1)

		#expect(first == SyncStamp(time: 1_793_836_800_000, counter: 0, device: "A"))
		#expect(second == SyncStamp(time: 1_793_836_800_000, counter: 1, device: "A"))
		#expect(later == SyncStamp(time: 1_793_836_801_000, counter: 0, device: "A"))
	}

	@Test func aClockGoingBackwardsStillMovesForward() {
		var clock = SyncClock(device: "A", offset: 0)
		let first = clock.tick(at: Self.start)
		let second = clock.tick(at: Self.start - 60)
		#expect(second > first)
		#expect(second.time == first.time)
	}

	/// The edit made after reading another device's beats it, even when this device's clock is behind
	@Test func ticksAfterReceivingBeatWhatWasReceived() {
		var clock = SyncClock(device: "A", offset: 0)
		let fast = SyncStamp(time: 1_793_836_900_000, counter: 7, device: "Z")
		clock.receive(fast)
		let next = clock.tick(at: Self.start)

		#expect(next > fast)
		#expect(next == SyncStamp(time: fast.time, counter: 8, device: "A"))
	}

	@Test func receivingAnOlderStampChangesNothing() {
		var clock = SyncClock(device: "A", offset: 0)
		let mine = clock.tick(at: Self.start)
		clock.receive(SyncStamp(time: 1, counter: 0, device: "Z"))
		#expect(clock.last == mine)
	}

	// MARK: - Offset

	@Test func theFirstServerTimeIsTakenAsIs() {
		var clock = SyncClock(device: "A")
		#expect(clock.offset == nil)
		clock.adjust(serverTime: Self.start + 30, at: Self.start)
		#expect(clock.offset == 30000)
		#expect(clock.now(Self.start) == 1_793_836_830_000)
	}

	@Test func laterServerTimesAreSmoothed() {
		var clock = SyncClock(device: "A", offset: 0)
		clock.adjust(serverTime: Self.start + 20, at: Self.start)
		#expect(clock.offset == 5000)

		// One slow reply barely moves it
		clock.adjust(serverTime: Self.start, at: Self.start)
		#expect(clock.offset == 3750)
	}

	@Test func aChangedDeviceClockIsTakenAsIs() {
		var clock = SyncClock(device: "A", offset: 0)
		clock.adjust(serverTime: Self.start, at: Self.start + 3600)
		#expect(clock.offset == -3_600_000)
		#expect(clock.tick(at: Self.start + 3600).time == 1_793_836_800_000)
	}

	/// A device an hour fast stamps at server time, so it can't win every merge
	@Test func stampsUseTheCorrectedTime() {
		var fast = SyncClock(device: "fast", offset: -3_600_000)
		var honest = SyncClock(device: "honest", offset: 0)
		let early = fast.tick(at: Self.start + 3600)
		let late = honest.tick(at: Self.start + 1)
		#expect(late > early)
	}

	@Test func forgettingTheOffsetMeasuresAgain() {
		var clock = SyncClock(device: "A", offset: 1234)
		clock.forgetOffset()
		#expect(clock.offset == nil)
		clock.adjust(serverTime: Self.start + 2, at: Self.start)
		#expect(clock.offset == 2000)
	}

	// MARK: - Coding

	@Test func coding() throws {
		let stamp = SyncStamp(time: 5, counter: 1, device: "A")
		let encoder = JSONEncoder()
		encoder.outputFormatting = .sortedKeys
		#expect(try String(decoding: encoder.encode(stamp), as: UTF8.self) == #"{"counter":1,"device":"A","time":5}"#)

		var clock = SyncClock(device: "A", offset: 12)
		_ = clock.tick(at: Self.start)
		#expect(try JSONDecoder().decode(SyncClock.self, from: encoder.encode(clock)) == clock)
	}
}
