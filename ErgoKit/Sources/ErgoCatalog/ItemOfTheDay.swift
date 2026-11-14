//
//  ItemOfTheDay.swift
//  ErgoKit
//
//  Created by Adon Omeri on 8/11/2026.
//

import Foundation

/// The library entry of the day, the same on every device without any of them asking a server.
///
/// `itemOfTheDay.json` is the order, made once by hashing every entry's `category/id` (see `hash`), which looks random
/// but never changes. The day number picks a place in it and wraps round at the end, so nothing repeats until the whole
/// list has been shown (about five years at the full library's size). A filter keeps only some categories of that same
/// order, so it stays steady while the filter is changed.
///
/// The file only ever grows at the end: when the library gets entries, append them (hashed among themselves) in the same
/// release and never reorder or remove a line. Devices on different versions then agree on every day inside the shorter
/// list. An entry the library no longer has is skipped to the next one, so no other day moves.
/// Past the end of the shorter list, or after a filter wraps round, versions can differ until everyone has updated.
public enum ItemOfTheDay {
	/// Every category of the library but symbols, which are the keyboard's glyphs and not something to read about
	public static let categories = ["biases", "concepts", "fallacies", "paradoxes", "philosophers", "razors", "arguments"]

	/// The pinned order, as `category/id`. Empty only if the package's resources are broken.
	public static let pinned: [String] = {
		struct File: Decodable {
			let order: [String]
		}
		guard
			let url = LibraryCatalog.url(of: "itemOfTheDay"),
			let data = try? Data(contentsOf: url),
			let file = try? JSONDecoder().decode(File.self, from: data)
		else {
			return []
		}
		return file.order
	}()

	/// `category/id`, or nil when the filter leaves nothing. An empty `categories` means all of them.
	public static func entry(
		on date: Date = .now,
		categories filter: Set<String> = [],
		among ids: some Collection<String> = LibraryCatalog.entryIDs,
		pinned: [String] = ItemOfTheDay.pinned,
		calendar: Calendar = .current
	) -> String? {
		let existing = Set(ids)
		let order = order(categories: filter, among: existing, pinned: pinned, includingMissing: true)
		guard !order.isEmpty else { return nil }
		let start = dayNumber(of: date, calendar: calendar) % order.count
		return (0 ..< order.count).lazy.map { order[(start + $0) % order.count] }.first { existing.contains($0) }
	}

	/// The whole cycle for a filter, first day first. Entries the library has that the file doesn't yet come last.
	/// `includingMissing` keeps the file's entries that `ids` no longer has, which `entry` needs to keep days in place.
	public static func order(
		categories filter: Set<String> = [],
		among ids: some Collection<String> = LibraryCatalog.entryIDs,
		pinned: [String] = ItemOfTheDay.pinned,
		includingMissing: Bool = false
	) -> [String] {
		let allowed = filter.isEmpty ? Set(categories) : filter.intersection(categories)
		func isAllowed(_ id: String) -> Bool {
			id.split(separator: "/").first.map { allowed.contains(String($0)) } ?? false
		}

		let existing = Set(ids)
		let known = Set(pinned)
		let added = existing
			.filter { !known.contains($0) && isAllowed($0) }
			.map { ($0, hash($0)) }
			.sorted { ($0.1, $0.0) < ($1.1, $1.0) }
			.map(\.0)
		return pinned.filter { isAllowed($0) && (includingMissing || existing.contains($0)) } + added
	}

	/// The first day of the list, whose item is the first of `pinned`. Never change it: every day would move.
	/// Earlier dates show that first item too.
	public static let startDate = DateComponents(year: 2026, month: 11, day: 8)

	/// Days since `startDate` on the calendar's own date, so everyone's day changes at their midnight. Never negative.
	static func dayNumber(of date: Date, calendar: Calendar) -> Int {
		let parts = calendar.dateComponents([.year, .month, .day], from: date)
		var utc = Calendar(identifier: .gregorian)
		utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
		let day = utc.date(from: parts) ?? date
		let start = utc.date(from: startDate) ?? day
		let days = utc.dateComponents([.day], from: start, to: day).day ?? 0
		return max(days, 0)
	}

	/// FNV-1a, then SplitMix64's mixing, since FNV alone leaves similar ids close together.
	/// Written out because `Hasher` and `hashValue` differ between launches.
	static func hash(_ text: String) -> UInt64 {
		var value: UInt64 = 0xCBF2_9CE4_8422_2325
		for byte in text.utf8 {
			value = (value ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
		}
		value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
		value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
		return value ^ (value >> 31)
	}
}
