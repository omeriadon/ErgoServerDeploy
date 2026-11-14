//
//  PracticeTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 14/11/2026.
//

@testable import ErgoCatalog
import Foundation
import Testing

struct PracticeTests {
	private static let library = try? PracticeDeck.loadLibrary()

	private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
	private let day: TimeInterval = 86400

	private func entry(_ id: String, tag: String = "a", summary: String? = nil, examples: [String] = []) -> PracticeEntry {
		PracticeEntry(category: "fallacies", id: id, name: "Name \(id)", summary: summary ?? "About \(id).", tags: [tag], examples: examples)
	}

	private var small: PracticeDeck {
		PracticeDeck(entries: (1 ... 8).map { entry("e\($0)", tag: $0 <= 4 ? "a" : "b") })
	}

	// MARK: - Hiding names

	@Test func redactionHidesWholeWordsOnly() {
		#expect(PracticeText.redacting(["Bundle theory"], in: "Bundle theory says an object is a bundle.") == "___ says an object is a bundle.")
		#expect(PracticeText.redacting(["ass"], in: "A class of assets.") == "A class of assets.")
		#expect(PracticeText.redacting(["Hume"], in: "HUME and hume, not Humean.") == "___ and ___, not Humean.")
		#expect(PracticeText.mentions("Straw man", in: "a straw man!"))
		#expect(!PracticeText.mentions("man", in: "a mankind"))
	}

	@Test func noLibraryCardGivesItsNameAway() throws {
		let deck = try #require(Self.library)
		var checked = 0
		for card in deck.cards {
			guard case let .library(category, id) = card.source, let entry = deck.entry(category: category, id: id) else { continue }
			let shown = card.kind == .identify ? card.prompts : [card.answer]
			for text in shown {
				#expect(!PracticeText.mentionsAny(entry.hiddenNames, in: text), "\(card.id) shows its name")
			}
			checked += 1
		}
		#expect(checked > 1000)
	}

	@Test func everyCategoryHasCardsOfBothKinds() throws {
		let deck = try #require(Self.library)
		for category in PracticeDeck.categories {
			let kinds = Set(deck.cards.filter { $0.topic == category }.map(\.kind))
			#expect(kinds == [.identify, .define], "\(category)")
		}
	}

	@Test func cardIDsAreUnique() throws {
		let deck = try #require(Self.library)
		#expect(Set(deck.cards.map(\.id)).count == deck.cards.count)
	}

	@Test func anExampleThatNamesItselfIsNotUsed() {
		let named = entry("x", examples: ["Name x strikes again.", "Someone dodges the question."])
		let deck = PracticeDeck(entries: [named] + (1 ... 4).map { entry("e\($0)") })
		let card = deck.cards.first { $0.id == "fallacies/x/identify" }
		#expect(card?.prompts == ["Someone dodges the question."])
	}

	// MARK: - Questions

	@Test(arguments: [1, 2, 3, 99] as [UInt64])
	func everyQuestionHasFourDifferentChoicesWithTheAnswerOnce(seed: UInt64) throws {
		let deck = try #require(Self.library)
		var random = SeededRandom(seed: seed)
		for _ in 0 ..< 300 {
			let card = deck.cards[Int.random(in: 0 ..< deck.cards.count, using: &random)]
			let question = deck.question(for: card, using: &random)
			#expect(question.choices.count == PracticeDeck.distractorCount + 1, "\(card.id)")
			#expect(Set(question.choices.map { $0.lowercased() }).count == question.choices.count, "\(card.id)")
			#expect(question.answer == card.answer)
			#expect(question.choices.count { $0 == card.answer } == 1)
		}
	}

	@Test func distractorsShareATagFirst() throws {
		var random = SeededRandom(seed: 7)
		let deck = small
		let card = try #require(deck.cards.first { $0.id == "fallacies/e1/identify" })
		let question = deck.question(for: card, using: &random)
		#expect(Set(question.choices) == ["Name e1", "Name e2", "Name e3", "Name e4"])
	}

	@Test func theSameSeedAsksTheSameWay() throws {
		let deck = try #require(Self.library)
		let card = try #require(deck.cards.first { $0.topic == "fallacies" && $0.kind == .identify })
		var first = SeededRandom(seed: 42)
		var second = SeededRandom(seed: 42)
		#expect(deck.question(for: card, using: &first) == deck.question(for: card, using: &second))
	}

	@Test func courseCardsKeepValidThenInvalid() {
		let card = PracticeCard.exercise(lessonID: "l", lessonTitle: "L", argument: "X ∴ X", reading: "r", isValid: false, explanation: "e")
		var random = SeededRandom(seed: 1)
		let question = small.adding([card]).question(for: card, using: &random)
		#expect(question.choices == [PracticeCard.validChoice, PracticeCard.invalidChoice])
		#expect(question.correctIndex == 1)
	}

	// MARK: - Scheduling

	@Test func rightAnswersWaitLongerAndAWrongOneStartsAgain() {
		var progress = PracticeProgress()
		progress.record("c", correct: true, at: start)
		#expect(progress.reviews["c"] == .init(box: 1, due: start + day))
		progress.record("c", correct: true, at: start + day)
		#expect(progress.reviews["c"] == .init(box: 2, due: start + 3 * day))
		for _ in 0 ..< 10 {
			progress.record("c", correct: true, at: start)
		}
		#expect(progress.reviews["c"]?.box == PracticeProgress.intervals.count)
		progress.record("c", correct: false, at: start)
		#expect(progress.reviews["c"] == .init(box: 1, due: start + day))
	}

	@Test func dueCardsComeFirstThenNewOnes() {
		let cards = small.cards
		var progress = PracticeProgress()
		progress.record(cards[0].id, correct: true, at: start)
		progress.record(cards[1].id, correct: true, at: start - day)
		progress.record(cards[2].id, correct: true, at: start + 5 * day)

		#expect(progress.dueCount(at: start + day) == 2)
		let plan = progress.plan(cards, at: start + day, limit: 5, newLimit: 2)
		#expect(plan.prefix(2).map(\.id) == [cards[1].id, cards[0].id])
		#expect(plan.count == 4)
		#expect(plan.dropFirst(2).allSatisfy { progress.isNew($0.id) })
		#expect(plan == progress.plan(cards, at: start + day, limit: 5, newLimit: 2))
	}

	@Test func aPlanNeverPassesItsLimit() {
		let cards = small.cards
		var progress = PracticeProgress()
		for card in cards {
			progress.record(card.id, correct: false, at: start)
		}
		#expect(progress.plan(cards, at: start + day, limit: 5).count == 5)
	}

	@Test func progressRoundTrips() throws {
		var progress = PracticeProgress()
		progress.record("fallacies/straw-man/identify", correct: true, at: start)
		let data = try JSONEncoder().encode(progress)
		#expect(try JSONDecoder().decode(PracticeProgress.self, from: data) == progress)
	}

	// MARK: - Sessions

	@Test func aWrongCardComesBackOnceAndOnlyItsFirstAnswerCounts() throws {
		var random = SeededRandom(seed: 3)
		let deck = small
		let cards = Array(deck.cards.prefix(3))
		var session = PracticeSession(cards: cards, deck: deck, using: &random)
		var asked = 0
		var firsts = 0
		while let question = session.current {
			asked += 1
			// Wrong the first time each card is seen, right after
			let wrong = (question.correctIndex + 1) % question.choices.count
			let choice = session.firstAnswers[question.card.id] == nil ? wrong : question.correctIndex
			let answered = session.choose(choice)
			let result = try #require(answered)
			let again = session.choose(0)
			#expect(again == nil)
			if result.isFirst {
				firsts += 1
			}
			session.next(using: &random)
			#expect(asked < 20)
		}
		#expect(asked == 6)
		#expect(firsts == 3)
		#expect(session.correctCount == 0)
		#expect(session.answeredCount == 3)
	}
}

/// SplitMix64, so a seed that fails can be run again and fails the same way
private struct SeededRandom: RandomNumberGenerator {
	var state: UInt64

	init(seed: UInt64) {
		state = seed
	}

	mutating func next() -> UInt64 {
		state &+= 0x9E37_79B9_7F4A_7C15
		var z = state
		z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
		z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
		return z ^ (z >> 31)
	}
}
