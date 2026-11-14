//
//  ItemOfTheDayTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 8/11/2026.
//

@testable import ErgoCatalog
import Foundation
import Testing

struct ItemOfTheDayTests {
	private var calendar: Calendar {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = .gmt
		return calendar
	}

	private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
		calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
	}

	@Test func theHashDoesNotChange() {
		// Pinned: a different value here would reshuffle every day for everyone
		#expect(ItemOfTheDay.hash("fallacies/straw-man") == 0xD36A_BCA8_F53D_835F)
	}

	@Test func theCycleIsEveryEntryOnce() {
		let ids = LibraryCatalog.entryIDs.filter { !$0.hasPrefix("symbols/") }
		let order = ItemOfTheDay.order()
		#expect(order.count == ids.count)
		#expect(Set(order) == ids)
	}

	@Test func everyDayOfTheCycleIsDifferent() {
		let first = date(2026, 11, 8)
		let count = 200
		let seen = (0 ..< count).compactMap { offset in
			ItemOfTheDay.entry(on: first.addingTimeInterval(Double(offset) * 86400), calendar: calendar)
		}
		#expect(Set(seen).count == count)
	}

	@Test func theFileCoversTheLibraryOnceEach() {
		// Fails when the library gains an entry: append it to itemOfTheDay.json, hashed among the new ones, never reorder
		let ids = LibraryCatalog.entryIDs.filter { !$0.hasPrefix("symbols/") }
		#expect(Set(ItemOfTheDay.pinned).count == ItemOfTheDay.pinned.count)
		#expect(Set(ItemOfTheDay.pinned) == ids)
	}

	@Test func newEntriesGoLastAndMoveNoDay() {
		let ids = LibraryCatalog.entryIDs
		let before = ItemOfTheDay.order(among: ids)
		let after = ItemOfTheDay.order(among: ids.union(["fallacies/brand-new", "concepts/another-new"]))
		#expect(Array(after.prefix(before.count)) == before)
		#expect(Set(after.suffix(2)) == ["fallacies/brand-new", "concepts/another-new"])
	}

	@Test func aRemovedEntryMovesOnlyItsOwnDay() {
		let order = ItemOfTheDay.pinned
		let gone = order[10]
		let ids = LibraryCatalog.entryIDs.subtracting([gone])
		let first = date(2026, 11, 8)
		func entry(_ day: Int, _ ids: Set<String>) -> String? {
			ItemOfTheDay.entry(on: first.addingTimeInterval(Double(day) * 86400), among: ids, calendar: calendar)
		}
		#expect(entry(10, ids) == order[11])
		#expect(entry(9, ids) == order[9])
		#expect(entry(11, ids) == order[11])
	}

	@Test func theStartDayIsTheFirstEntry() {
		#expect(ItemOfTheDay.entry(on: date(2026, 11, 8), calendar: calendar) == ItemOfTheDay.pinned.first)
		#expect(ItemOfTheDay.entry(on: date(2026, 11, 9), calendar: calendar) == ItemOfTheDay.pinned[1])
		#expect(ItemOfTheDay.entry(on: date(2026, 1, 1), calendar: calendar) == ItemOfTheDay.pinned.first)
	}

	@Test func theDayChangesAtMidnightOnTheCalendar() {
		let morning = ItemOfTheDay.entry(on: date(2026, 11, 8, hour: 0), calendar: calendar)
		let night = ItemOfTheDay.entry(on: date(2026, 11, 8, hour: 23), calendar: calendar)
		let next = ItemOfTheDay.entry(on: date(2026, 11, 9, hour: 0), calendar: calendar)
		#expect(morning == night)
		#expect(morning != next)
	}

	@Test func aFilterKeepsTheSameOrder() {
		let all = ItemOfTheDay.order()
		let some = ItemOfTheDay.order(categories: ["fallacies", "philosophers"])
		#expect(some == all.filter { $0.hasPrefix("fallacies/") || $0.hasPrefix("philosophers/") })
		#expect(ItemOfTheDay.entry(categories: ["fallacies"])?.hasPrefix("fallacies/") == true)
	}

	@Test func nothingToShowGivesNil() {
		#expect(ItemOfTheDay.entry(categories: ["symbols"]) == nil)
		#expect(ItemOfTheDay.entry(among: [String]()) == nil)
	}

	@Test func theOrderLooksRandom() {
		// Neighbouring ids of one category must not stay neighbours, or the day after a fallacy is another fallacy
		let order = ItemOfTheDay.order()
		let sameCategoryAsNext = zip(order, order.dropFirst()).filter { $0.0.split(separator: "/")[0] == $0.1.split(separator: "/")[0] }.count
		// Concepts are over half the library, so a fair shuffle repeats a category about 40% of the time
		let share = Double(sameCategoryAsNext) / Double(order.count - 1)
		#expect((0.3 ... 0.5).contains(share), "\(share)")
	}
}
