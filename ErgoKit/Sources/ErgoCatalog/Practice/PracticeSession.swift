//
//  PracticeSession.swift
//  ErgoKit
//
//  Created by Adon Omeri on 14/11/2026.
//

import Foundation

/// One sitting: a card at a time, answered, then the next. A card answered wrong comes back once at the end, but only
/// its first answer counts towards progress.
public struct PracticeSession: Sendable {
	public private(set) var current: PracticeQuestion?

	/// The choice made for `current`, nil until it's answered
	public private(set) var chosen: Int?

	/// Each card's first answer, by id
	public private(set) var firstAnswers: [String: Bool] = [:]

	/// How many cards the session started with
	public let count: Int

	private let deck: PracticeDeck
	private var queue: [PracticeCard]
	private var repeated: Set<String> = []

	public init(cards: [PracticeCard], deck: PracticeDeck, using random: inout some RandomNumberGenerator) {
		self.deck = deck
		count = cards.count
		queue = cards.shuffled(using: &random)
		next(using: &random)
	}

	public var isFinished: Bool {
		current == nil
	}

	public var isAnswered: Bool {
		chosen != nil
	}

	public var correctCount: Int {
		firstAnswers.values.count { $0 }
	}

	/// Cards answered at least once
	public var answeredCount: Int {
		firstAnswers.count
	}

	/// Whether `index` is right, and whether this was the card's first answer, which is the one to record.
	/// Nil once the current card is already answered.
	public mutating func choose(_ index: Int) -> (isCorrect: Bool, isFirst: Bool)? {
		guard let current, chosen == nil else { return nil }
		chosen = index
		let isCorrect = index == current.correctIndex
		let id = current.card.id
		let isFirst = firstAnswers[id] == nil
		if isFirst {
			firstAnswers[id] = isCorrect
		}
		if !isCorrect, !repeated.contains(id) {
			repeated.insert(id)
			queue.append(current.card)
		}
		return (isCorrect, isFirst)
	}

	public mutating func next(using random: inout some RandomNumberGenerator) {
		chosen = nil
		current = queue.isEmpty ? nil : deck.question(for: queue.removeFirst(), using: &random)
	}
}
