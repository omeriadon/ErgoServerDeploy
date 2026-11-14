//
//  PracticeDeck.swift
//  ErgoKit
//
//  Created by Adon Omeri on 14/11/2026.
//

import Foundation

/// What practice needs from one library entry
public struct PracticeEntry: Hashable, Sendable {
	public let category: String
	public let id: String
	public let name: String
	public let aliases: [String]
	public let summary: String
	public let tags: [String]
	public let examples: [String]

	/// Ids of entries it's easily mistaken for, which make the hardest wrong answers
	public let lookalikes: [String]

	public init(
		category: String,
		id: String,
		name: String,
		aliases: [String] = [],
		summary: String,
		tags: [String] = [],
		examples: [String] = [],
		lookalikes: [String] = []
	) {
		self.category = category
		self.id = id
		self.name = name
		self.aliases = aliases
		self.summary = summary
		self.tags = tags
		self.examples = examples
		self.lookalikes = lookalikes
	}

	/// What a card about it has to hide: its name and aliases, and for a person each part of their name too, since a
	/// description often says "Kant" after "Immanuel Kant"
	public var hiddenNames: [String] {
		var names = [name] + aliases
		if category == "philosophers" {
			names += name.split { !$0.isLetter && $0 != "'" }.map(String.init).filter { $0.count >= 3 }
		}
		return names
	}

	/// The summary with its own name hidden
	public var redactedSummary: String {
		PracticeText.redacting(hiddenNames, in: summary)
	}
}

/// Every card the library can make, and the wrong answers for each. Built once, then asked from many times.
public struct PracticeDeck: Sendable {
	/// The categories practice draws on, in the library grid's order
	public static let categories = ["biases", "concepts", "fallacies", "symbols", "paradoxes", "philosophers", "razors", "arguments"]

	/// Categories whose examples are about something else, like a symbol's formulas, so only the summary identifies them
	static let summaryOnly: Set<String> = ["symbols", "philosophers"]

	public let cards: [PracticeCard]
	private let entries: [String: [PracticeEntry]]
	private let positions: [String: Int]

	public init(entries list: [PracticeEntry], extraCards: [PracticeCard] = []) {
		var entries: [String: [PracticeEntry]] = [:]
		var positions: [String: Int] = [:]
		for entry in list {
			positions["\(entry.category)/\(entry.id)"] = entries[entry.category, default: []].count
			entries[entry.category, default: []].append(entry)
		}
		self.entries = entries
		self.positions = positions

		var cards: [PracticeCard] = []
		for entry in list where (entries[entry.category]?.count ?? 0) > Self.distractorCount {
			cards += Self.cards(for: entry)
		}
		self.cards = cards + extraCards
	}

	private init(cards: [PracticeCard], entries: [String: [PracticeEntry]], positions: [String: Int]) {
		self.cards = cards
		self.entries = entries
		self.positions = positions
	}

	/// The same deck with other cards, like the course's, added
	public func adding(_ extra: [PracticeCard]) -> PracticeDeck {
		PracticeDeck(cards: cards + extra, entries: entries, positions: positions)
	}

	public func entry(category: String, id: String) -> PracticeEntry? {
		positions["\(category)/\(id)"].flatMap { entries[category]?[$0] }
	}

	/// Three wrong answers and the right one
	public static let distractorCount = 3

	static func cards(for entry: PracticeEntry) -> [PracticeCard] {
		let names = entry.hiddenNames
		let source = PracticeCard.Source.library(category: entry.category, id: entry.id)
		var cards: [PracticeCard] = []

		var prompts: [String] = []
		if !summaryOnly.contains(entry.category) {
			prompts = entry.examples.filter { !$0.isEmpty && !PracticeText.mentionsAny(names, in: $0) }
		}
		let summary = entry.redactedSummary
		if prompts.isEmpty, !summary.isEmpty {
			prompts = [summary]
		}
		if !prompts.isEmpty {
			cards.append(PracticeCard(
				id: "\(entry.category)/\(entry.id)/\(PracticeCard.Kind.identify.rawValue)",
				kind: .identify,
				topic: entry.category,
				source: source,
				title: entry.name,
				prompts: prompts,
				answer: entry.name,
				explanation: entry.summary.isEmpty ? nil : entry.summary
			))
		}

		if !summary.isEmpty {
			cards.append(PracticeCard(
				id: "\(entry.category)/\(entry.id)/\(PracticeCard.Kind.define.rawValue)",
				kind: .define,
				topic: entry.category,
				source: source,
				title: entry.name,
				prompts: [entry.name],
				answer: summary
			))
		}
		return cards
	}

	// MARK: - Asking

	/// The card as it's asked this time: a prompt, and the answer among wrong ones from the same category, the
	/// entry's lookalikes and those sharing a tag first
	public func question(for card: PracticeCard, using random: inout some RandomNumberGenerator) -> PracticeQuestion {
		let prompt = card.prompts.randomElement(using: &random) ?? card.title
		if let fixed = card.fixedChoices {
			return PracticeQuestion(card: card, prompt: prompt, choices: fixed, correctIndex: fixed.firstIndex(of: card.answer) ?? 0)
		}

		var choices = [card.answer] + distractors(for: card, using: &random)
		choices.shuffle(using: &random)
		return PracticeQuestion(card: card, prompt: prompt, choices: choices, correctIndex: choices.firstIndex(of: card.answer) ?? 0)
	}

	private func distractors(for card: PracticeCard, using random: inout some RandomNumberGenerator) -> [String] {
		guard
			case let .library(category, id) = card.source,
			let entry = entry(category: category, id: id),
			let pool = entries[category]
		else {
			return []
		}

		let hidden = Set(entry.hiddenNames.map { $0.lowercased() })
		var chosen: [String] = []
		var seen: Set<String> = [card.answer.lowercased()]

		func consider(_ other: PracticeEntry) {
			guard chosen.count < Self.distractorCount, other.id != entry.id else { return }
			let text = card.kind == .define ? other.redactedSummary : other.name
			let key = text.lowercased()
			guard !text.isEmpty, !seen.contains(key), !hidden.contains(key) else { return }
			seen.insert(key)
			chosen.append(text)
		}

		let lookalikes = entry.lookalikes.compactMap { self.entry(category: category, id: $0) }.shuffled(using: &random)
		lookalikes.forEach(consider)

		let tags = Set(entry.tags)
		if !tags.isEmpty {
			pool.filter { !tags.isDisjoint(with: $0.tags) }.shuffled(using: &random).forEach(consider)
		}

		// Anything else in the category, sampled rather than shuffled, since concepts has over a thousand
		var attempts = 0
		while chosen.count < Self.distractorCount, attempts < 64 {
			consider(pool[Int.random(in: 0 ..< pool.count, using: &random)])
			attempts += 1
		}
		if chosen.count < Self.distractorCount {
			pool.forEach(consider)
		}
		return chosen
	}

	// MARK: - Loading

	/// The bundled library. Reads every file, so call it off the main actor.
	public static func loadLibrary() throws -> PracticeDeck {
		var entries: [PracticeEntry] = []
		for category in categories {
			guard let url = LibraryCatalog.url(of: category) else {
				throw CocoaError(.fileNoSuchFile)
			}
			entries += try Self.entries(in: Data(contentsOf: url), category: category)
		}
		return PracticeDeck(entries: entries)
	}

	static func entries(in data: Data, category: String) throws -> [PracticeEntry] {
		let file = try JSONDecoder().decode([String: [StoredEntry]].self, from: data)
		guard let items = file[category] else {
			throw CocoaError(.fileReadCorruptFile)
		}
		return items.map { item in
			PracticeEntry(
				category: category,
				id: item.id,
				name: item.name,
				aliases: item.aliases ?? [],
				summary: item.summary ?? "",
				tags: item.tags ?? [],
				examples: item.examples?.map(\.text) ?? [],
				lookalikes: item.lookalikes?.map(\.targetID) ?? []
			)
		}
	}

	/// Only the fields practice reads. Every other one is ignored.
	private struct StoredEntry: Decodable {
		struct Example: Decodable {
			let text: String
		}

		struct Lookalike: Decodable {
			let targetID: String
		}

		let id: String
		let name: String
		let aliases: [String]?
		let summary: String?
		let tags: [String]?
		let examples: [Example]?
		let lookalikes: [Lookalike]?
	}
}
