//
//  PracticeProgress.swift
//  ErgoKit
//
//  Created by Adon Omeri on 14/11/2026.
//

import Foundation

/// When each card practised so far is next due, as Leitner boxes: a right answer moves a card up a box, which waits
/// twice as long, and a wrong one sends it back to the first. Only card ids, boxes and dates, never what a card says.
///
/// Times are offsets from the clock passed in, never calendar days, so the same answers at the same times always give
/// the same schedule.
public struct PracticeProgress: Codable, Hashable, Sendable {
	public struct Review: Codable, Hashable, Sendable {
		/// 1 to `PracticeProgress.intervals.count`
		public var box: Int
		public var due: Date

		public init(box: Int, due: Date) {
			self.box = box
			self.due = due
		}
	}

	/// By card id
	public var reviews: [String: Review]

	public init(reviews: [String: Review] = [:]) {
		self.reviews = reviews
	}

	/// How long each box waits, first box first
	public static let intervals: [TimeInterval] = [1, 2, 4, 8, 16, 32].map { $0 * 86400 }

	public func isNew(_ id: String) -> Bool {
		reviews[id] == nil
	}

	public func isDue(_ id: String, at now: Date) -> Bool {
		reviews[id].map { $0.due <= now } ?? false
	}

	/// Cards practised before and due again by `now`
	public func dueCount(at now: Date) -> Int {
		reviews.values.count { $0.due <= now }
	}

	/// Cards in `cards` due by `now`
	public func dueCount(of cards: some Sequence<PracticeCard>, at now: Date) -> Int {
		cards.count { isDue($0.id, at: now) }
	}

	/// Cards in `cards` never practised
	public func newCount(of cards: some Sequence<PracticeCard>) -> Int {
		cards.count { isNew($0.id) }
	}

	/// After a card's first answer in a session
	public mutating func record(_ id: String, correct: Bool, at now: Date) {
		let box = correct ? min((reviews[id]?.box ?? 0) + 1, Self.intervals.count) : 1
		reviews[id] = Review(box: box, due: now.addingTimeInterval(Self.intervals[box - 1]))
	}

	/// What a session asks: the cards due, longest overdue first, then new ones in a fixed order that mixes the
	/// library up, at most `newLimit` of them. Never more than `limit` in all.
	public func plan(_ cards: [PracticeCard], at now: Date, limit: Int = 20, newLimit: Int = 10) -> [PracticeCard] {
		let due = cards
			.compactMap { card in reviews[card.id].flatMap { $0.due <= now ? (card, $0.due) : nil } }
			.sorted { ($0.1, $0.0.id) < ($1.1, $1.0.id) }
			.map(\.0)
			.prefix(limit)

		let room = min(newLimit, limit - due.count)
		guard room > 0 else { return Array(due) }

		let new = cards
			.filter { isNew($0.id) }
			.map { ($0, ItemOfTheDay.hash($0.id)) }
			.sorted { ($0.1, $0.0.id) < ($1.1, $1.0.id) }
			.prefix(room)
			.map(\.0)
		return Array(due) + new
	}
}
