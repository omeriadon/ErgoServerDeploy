//
//  SyncStamp.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import Foundation

/// When a field was written, as a hybrid logical clock: ordered by `time`, then `counter`, then `device`.
/// The newer stamp wins a merge.
public struct SyncStamp: Codable, Sendable, Hashable, Comparable {
	/// Milliseconds since 1970, corrected towards the server's clock
	public var time: Int64

	/// Orders stamps within one millisecond, and stamps a device makes after seeing one from a fast clock
	public var counter: Int

	/// Only breaks ties, so two devices never make equal stamps
	public var device: String

	public init(time: Int64, counter: Int, device: String) {
		self.time = time
		self.counter = counter
		self.device = device
	}

	public var date: Date {
		Date(timeIntervalSince1970: Double(time) / 1000)
	}

	public static func < (a: SyncStamp, b: SyncStamp) -> Bool {
		(a.time, a.counter, a.device) < (b.time, b.counter, b.device)
	}

	/// A stamp for something the server writes itself, always newer than `newest`, the newest stamp of the record it goes in.
	/// It has no clock to keep, so what's newest is passed in.
	public static func server(after newest: SyncStamp?, now: Date) -> SyncStamp {
		let time = max(SyncClock.milliseconds(now), newest?.time ?? .min)
		let counter = time == newest?.time ? (newest?.counter ?? 0) + 1 : 0
		return SyncStamp(time: time, counter: counter, device: "server")
	}
}

// MARK: - Clock

/// Makes this device's stamps. Every stamp it makes is newer than every stamp it has made or received,
/// so an edit made after reading another device's edit always wins over it, even with a slow clock.
public struct SyncClock: Codable, Sendable, Hashable {
	public let device: String

	/// The newest stamp made or received
	public private(set) var last: SyncStamp?

	/// Smoothed `serverTime - deviceTime` in milliseconds, so one device with a wrong clock can't win every merge.
	/// Nil until the first server time, and until then this device's stamps might be refused.
	public private(set) var offset: Int64?

	public init(device: String, last: SyncStamp? = nil, offset: Int64? = nil) {
		self.device = device
		self.last = last
		self.offset = offset
	}

	/// The device clock corrected by `offset`, in milliseconds since 1970
	public func now(_ deviceNow: Date = .now) -> Int64 {
		Self.milliseconds(deviceNow) + (offset ?? 0)
	}

	/// A stamp for a local change
	public mutating func tick(at deviceNow: Date = .now) -> SyncStamp {
		let time = max(now(deviceNow), last?.time ?? .min)
		let counter = time == last?.time ? (last?.counter ?? 0) + 1 : 0
		let stamp = SyncStamp(time: time, counter: counter, device: device)
		last = stamp
		return stamp
	}

	public mutating func receive(_ stamp: SyncStamp) {
		if last.map({ stamp > $0 }) ?? true {
			last = stamp
		}
	}

	// MARK: - Offset

	/// A jump this big is the device clock being changed, so it's taken as is instead of smoothed
	static let jump: Int64 = 60000

	/// Moves `offset` a quarter of the way towards what this server time says, so one slow response barely moves it
	public mutating func adjust(serverTime: Date, at deviceNow: Date = .now) {
		let sample = Self.milliseconds(serverTime) - Self.milliseconds(deviceNow)
		if let offset, abs(sample - offset) < Self.jump {
			self.offset = offset + (sample - offset) / 4
		} else {
			offset = sample
		}
	}

	/// For after the server refuses a stamp: the offset is wrong, so the next sync measures it again before pushing
	public mutating func forgetOffset() {
		offset = nil
	}

	/// Drops `last` back to `stamp`, for when local stamps came from a clock that turned out to be far ahead
	mutating func rewind(to stamp: SyncStamp?) {
		last = stamp
	}

	static func milliseconds(_ date: Date) -> Int64 {
		Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
	}
}
