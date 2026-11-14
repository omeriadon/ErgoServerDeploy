//
//  LogicFuzzTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 11/11/2026.
//

import ErgoLogic
import Foundation
import Testing

/// Random logic, checked against answers worked out the slow way. A seed that fails always fails the same way.
struct LogicFuzzTests {
	let letters = LogicLetters.defaults
	let vocabulary = LogicInputVocabulary(letters: LogicLetters.defaults)

	func entries(_ formula: LogicFormula) -> [LogicKeyboardEntry] {
		vocabulary.entries(in: formula.text(letters: letters))
	}

	func argument(_ premises: [LogicFormula], _ conclusion: LogicFormula) -> [LogicKeyboardEntry] {
		var entries: [LogicKeyboardEntry] = []
		for (index, premise) in premises.enumerated() {
			if index > 0 {
				entries.append(.delimiter(","))
			}
			entries += self.entries(premise)
		}
		return entries + [.symbol("∴")] + self.entries(conclusion)
	}

	// MARK: - Printing and parsing

	@Test(arguments: 0 ..< 400 as Range<UInt64>)
	func whatIsPrintedParsesBackToTheSameFormula(seed: UInt64) throws {
		var random = SeededRandom(seed: seed)
		let formula = LogicFormula.random(depth: 5, letters: 6, using: &random)

		let parse = LogicParser.parse(entries(formula))

		#expect(parse.diagnostics.isEmpty, "\(formula.text(letters: letters))")
		let read = try #require(parse.argument.premises.first?.formula)
		#expect(parse.argument.premises.count == 1)
		// Brackets may come back differently, so the meaning is compared, then the text
		#expect(everyRow.allSatisfy { read.isTrue($0) == formula.isTrue($0) }, "\(formula.text(letters: letters))")
		#expect(read.text(letters: letters) == formula.text(letters: letters))
	}

	// MARK: - The truth table

	@Test(arguments: 1000 ..< 1400 as Range<UInt64>)
	func statusesMatchEveryRow(seed: UInt64) {
		var random = SeededRandom(seed: seed)
		let formula = LogicFormula.random(depth: 4, letters: 3, using: &random)

		let trueRows = everyRow.count(where: formula.isTrue)
		let expected: LogicStatus = trueRows == everyRow.count ? .tautology : trueRows == 0 ? .contradiction : .contingent

		#expect(LogicChecker.status(of: formula) == expected, "\(formula.text(letters: letters))")
	}

	@Test(arguments: 2000 ..< 2500 as Range<UInt64>)
	func verdictsMatchEveryRow(seed: UInt64) throws {
		var random = SeededRandom(seed: seed)
		let premises = (0 ..< Int.random(in: 1 ... 3, using: &random)).map { _ in
			LogicFormula.random(depth: 3, letters: 4, using: &random)
		}
		let conclusion = LogicFormula.random(depth: 3, letters: 4, using: &random)
		let text = vocabulary.text(for: argument(premises, conclusion))

		func fails(_ row: [Int: Bool]) -> Bool {
			premises.allSatisfy { $0.isTrue(row) } && !conclusion.isTrue(row)
		}

		let analysis = LogicChecker.analyze(argument(premises, conclusion))
		#expect(analysis.parse.diagnostics.isEmpty, "\(text)")

		switch try #require(analysis.verdict, "\(text)") {
			case .valid:
				#expect(!everyRow.contains(where: fails), "\(text)")
			case let .invalid(counterexample):
				// It has to fail however the letters it leaves out are set
				let matching = everyRow.filter { row in counterexample.allSatisfy { row[$0.key] == $0.value } }
				#expect(!matching.isEmpty && matching.allSatisfy(fails), "\(text) with \(counterexample)")
			case .undecided:
				Issue.record("Expected a truth table to settle \(text)")
		}
	}

	@Test(arguments: 3000 ..< 3200 as Range<UInt64>)
	func warningsAreTrueOfTheArgument(seed: UInt64) {
		var random = SeededRandom(seed: seed)
		let premises = (0 ..< Int.random(in: 1 ... 3, using: &random)).map { _ in
			LogicFormula.random(depth: 2, letters: 3, using: &random)
		}
		let conclusion = LogicFormula.random(depth: 2, letters: 3, using: &random)
		let analysis = LogicChecker.analyze(argument(premises, conclusion))
		let text = vocabulary.text(for: argument(premises, conclusion))

		let canAllBeTrue = everyRow.contains { row in premises.allSatisfy { $0.isTrue(row) } }
		#expect(analysis.warnings.contains(.inconsistentPremises) == !canAllBeTrue, "\(text)")

		for case let .circular(premise) in analysis.warnings {
			#expect(premises.indices.contains(premise), "\(text)")
		}
		for match in analysis.fallacies {
			#expect(match.premises.allSatisfy(premises.indices.contains), "\(text)")
		}
	}

	// MARK: - The prover

	/// □ in front of everything changes nothing about whether an argument is valid, but sends it to the prover instead of
	/// the truth table. So the two have to agree.
	@Test(arguments: 4000 ..< 4250 as Range<UInt64>)
	func theProverAgreesWithTheTruthTable(seed: UInt64) throws {
		var random = SeededRandom(seed: seed)
		let premises = (0 ..< Int.random(in: 1 ... 2, using: &random)).map { _ in
			LogicFormula.random(depth: 3, letters: 3, using: &random)
		}
		let conclusion = LogicFormula.random(depth: 3, letters: 3, using: &random)
		let text = vocabulary.text(for: argument(premises, conclusion))

		let isValid = !everyRow.contains { row in premises.allSatisfy { $0.isTrue(row) } && !conclusion.isTrue(row) }
		let boxed = LogicChecker.analyze(argument(premises.map(LogicFormula.necessarily), .necessarily(conclusion)))

		switch try #require(boxed.verdict, "\(text)") {
			case .valid:
				#expect(isValid, "\(text)")
			case .invalid:
				#expect(!isValid, "\(text)")
			case .undecided:
				Issue.record("Expected the prover to settle \(text) under □")
		}
	}

	/// □ or ◇ in front of a statement doesn't change whether it's always true, never true or neither
	@Test(arguments: 5000 ..< 5200 as Range<UInt64>)
	func theProverAgreesOnWhatIsAlwaysTrue(seed: UInt64) {
		var random = SeededRandom(seed: seed)
		let formula = LogicFormula.random(depth: 3, letters: 3, using: &random)

		let trueRows = everyRow.count(where: formula.isTrue)
		let expected: LogicStatus = trueRows == everyRow.count ? .tautology : trueRows == 0 ? .contradiction : .contingent

		#expect(LogicChecker.status(of: .possibly(formula)) == expected, "◇ \(formula.text(letters: letters))")
		#expect(LogicChecker.status(of: .necessarily(formula)) == expected, "□ \(formula.text(letters: letters))")
	}

	// MARK: - Equivalence

	@Test(arguments: 6000 ..< 6300 as Range<UInt64>)
	func equivalenceMatchesEveryRow(seed: UInt64) {
		var random = SeededRandom(seed: seed)
		let first = LogicFormula.random(depth: 3, letters: 3, using: &random)
		let second = LogicFormula.random(depth: 3, letters: 3, using: &random)

		let same = everyRow.allSatisfy { first.isTrue($0) == second.isTrue($0) }

		#expect(LogicEquivalence.equivalent(first, second) == same, "\(first.text(letters: letters)) and \(second.text(letters: letters))")
		#expect(LogicEquivalence.equivalent(first, .not(.not(first))) == true)
		#expect(LogicEquivalence.equivalent(first, .not(first)) == false)
	}

	// MARK: - Reading

	@Test(arguments: 7000 ..< 7300 as Range<UInt64>)
	func everythingThatParsesReads(seed: UInt64) throws {
		var random = SeededRandom(seed: seed)
		let premise = LogicFormula.random(depth: 4, letters: 6, using: &random)
		let conclusion = LogicFormula.random(depth: 4, letters: 6, using: &random)
		let parse = LogicParser.parse(argument([premise], conclusion))
		let descriptors = ["it rains", "", "the ground is wet", "", "", "the sky is grey"]

		let plain = try #require(LogicEnglish.text(for: parse, letters: letters, descriptors: LogicLetters.emptyDescriptors))
		let described = try #require(LogicEnglish.text(for: parse, letters: letters, descriptors: descriptors))

		#expect(!plain.isEmpty && !described.isEmpty)
		#expect(plain == LogicEnglish.text(for: parse, letters: letters, descriptors: LogicLetters.emptyDescriptors))
		// No symbol is left in what's read out
		let symbols = Set(LogicKeyboardEntry.symbolEntries.map { $0.glyph(letters: letters) }).subtracting(["(", ")", ",", "\n", "[", "]", "="])
		#expect(!symbols.contains { plain.contains($0) }, "\(plain)")
	}
}

/// Keys pressed at random. Nothing they make may crash, hang or point outside what was typed.
struct LogicKeystrokeFuzzTests {
	static let keys = LogicKeyboardEntry.variables + LogicKeyboardEntry.symbolEntries

	func check(_ entries: [LogicKeyboardEntry]) {
		let vocabulary = LogicInputVocabulary(letters: LogicLetters.defaults)
		let text = vocabulary.text(for: entries)
		let analysis = LogicChecker.analyze(entries)
		let bounds = 0 ... entries.count

		for diagnostic in analysis.parse.diagnostics {
			#expect(bounds.contains(diagnostic.range.lowerBound) && bounds.contains(diagnostic.range.upperBound), "\(text)")
			if let fix = diagnostic.fix {
				#expect(bounds.contains(fix.range.lowerBound) && bounds.contains(fix.range.upperBound), "\(text)")
			}
		}
		for statement in analysis.parse.argument.premises + [analysis.parse.argument.conclusion].compactMap(\.self) {
			#expect(bounds.contains(statement.range.lowerBound) && bounds.contains(statement.range.upperBound), "\(text)")
		}
		for definition in analysis.parse.definitions {
			#expect(bounds.contains(definition.range.lowerBound) && bounds.contains(definition.range.upperBound), "\(text)")
		}
		if !analysis.parse.diagnostics.isEmpty {
			#expect(analysis.verdict == nil, "\(text)")
		}

		// What's typed is what's shown, and reading it back gives the same keys
		#expect(vocabulary.entries(in: text) == entries, "\(text)")
		_ = LogicEnglish.text(for: analysis.parse, letters: LogicLetters.defaults, descriptors: LogicLetters.emptyDescriptors)

		// The same keys always get the same answer
		#expect(LogicChecker.analyze(entries) == analysis, "\(text)")
	}

	@Test(arguments: 0 ..< 600 as Range<UInt64>)
	func randomKeysNeverBreakTheChecker(seed: UInt64) {
		var random = SeededRandom(seed: seed)
		let count = Int.random(in: 0 ... 24, using: &random)
		check((0 ..< count).map { _ in Self.keys.randomElement(using: &random)! })
	}

	/// Mostly right, with a key or two wrong: what someone is really looking at while they type
	@Test(arguments: 1000 ..< 1400 as Range<UInt64>)
	func nearlyRightLogicNeverBreaksTheChecker(seed: UInt64) throws {
		var random = SeededRandom(seed: seed)
		let vocabulary = LogicInputVocabulary(letters: LogicLetters.defaults)
		let premise = LogicFormula.random(depth: 3, letters: 4, using: &random)
		let conclusion = LogicFormula.random(depth: 3, letters: 4, using: &random)
		var entries = vocabulary.entries(in: premise.text(letters: LogicLetters.defaults) + "∴" + conclusion.text(letters: LogicLetters.defaults))

		for _ in 0 ..< Int.random(in: 1 ... 3, using: &random) {
			let index = Int.random(in: 0 ... entries.count, using: &random)
			switch Int.random(in: 0 ..< 3, using: &random) {
				case 0 where index < entries.count:
					entries.remove(at: index)
				case 1 where index < entries.count:
					entries[index] = try #require(Self.keys.randomElement(using: &random))
				default:
					try entries.insert(#require(Self.keys.randomElement(using: &random)), at: index)
			}
		}
		check(entries)
	}

	@Test func everyPrefixOfALongArgumentIsSafe() {
		let vocabulary = LogicInputVocabulary(letters: LogicLetters.defaults)
		let entries = vocabulary.entries(in: "∀X(P(X)→Q(X)),□(X∈Y∪Z→¬◇(X=P)),X≔Y∧Z\n[X⊕Y]↔(P⊆Q)∴∃X(Q(X)∧X∉∅)∎")
		for length in 0 ... entries.count {
			check(Array(entries.prefix(length)))
		}
	}

	// MARK: - As big as it gets

	func problems(_ entries: [LogicKeyboardEntry]) -> [LogicProblem] {
		LogicChecker.analyze(entries).parse.diagnostics.map(\.problem)
	}

	func repeated(_ entry: LogicKeyboardEntry, _ count: Int) -> [LogicKeyboardEntry] {
		Array(repeating: entry, count: count)
	}

	/// X, then `joiner` X until it's `length` symbols
	func chain(_ joiner: String, length: Int) -> [LogicKeyboardEntry] {
		[.variable(1)] + (0 ..< (length - 1) / 2).flatMap { [.symbol(joiner), .variable($0 % 6 + 1)] }
	}

	@Test func nestingStopsAtTheLimit() {
		let limit = LogicParser.maximumDepth
		#expect(problems(repeated(.delimiter("("), limit - 1) + [.variable(1)] + repeated(.delimiter(")"), limit - 1)).isEmpty)
		#expect(problems(repeated(.symbol("¬"), limit - 1) + [.variable(1)]).isEmpty)
		#expect(problems(repeated(.symbol("□"), limit - 1) + [.variable(1)]).isEmpty)
	}

	/// What used to crash: every level of brackets is a level of the parser's stack
	@Test(arguments: [25, 100, 1000, 20000])
	func nestingPastTheLimitIsAProblemAndNotACrash(depth: Int) {
		let open = repeated(.delimiter("("), depth)
		let close = repeated(.delimiter(")"), depth)
		let limit = LogicParser.maximumDepth
		// Brackets this deep are also over the length, when they're all one statement
		let expected: [LogicProblem] = depth * 2 + 1 > LogicParser.maximumStatementLength ? [.tooLong(limit: LogicParser.maximumStatementLength)] : [.tooDeep(limit: limit)]

		#expect(problems(open + [.variable(1)] + close) == expected)
		for key in ["¬", "□", "◇"] where depth < LogicParser.maximumStatementLength {
			#expect(problems(repeated(.symbol(key), depth) + [.variable(1)]) == [.tooDeep(limit: limit)])
		}
		check(open)
		check(close)
		check(open + close)
	}

	@Test(arguments: ["∧", "∨", "⊕", "→", "↔"])
	func theLongestChainIsStillChecked(joiner: String) {
		let entries = chain(joiner, length: LogicParser.maximumStatementLength)
		let analysis = LogicChecker.analyze(entries + [.symbol("∴")] + entries)

		#expect(analysis.parse.diagnostics.isEmpty)
		#expect(analysis.verdict == .valid)
		#expect(LogicEnglish.text(for: analysis.parse, letters: LogicLetters.defaults, descriptors: LogicLetters.emptyDescriptors) != nil)

		#expect(problems(chain(joiner, length: LogicParser.maximumStatementLength + 2)) == [.tooLong(limit: LogicParser.maximumStatementLength)])
	}

	/// `letter ≔ value`, on its own line
	func definition(_ slot: Int, _ value: [LogicKeyboardEntry]) -> [LogicKeyboardEntry] {
		[.variable(slot), .symbol("≔")] + value + [.delimiter("\n")]
	}

	/// Each letter is a long chain with the next letter once in it, so written out it's as deep as all of them together
	@Test func theDeepestDefinitionsAreStillChecked() {
		var entries: [LogicKeyboardEntry] = []
		for slot in 1 ... 5 {
			// R→R→…→next, which reads from the right, so the next letter is at the bottom
			let filler = (0 ..< 50).flatMap { _ in [LogicKeyboardEntry.variable(6), .symbol("→")] }
			entries += definition(slot, filler + [.variable(slot + 1)])
		}
		entries += [.variable(1), .symbol("∴"), .variable(1)]

		let analysis = LogicChecker.analyze(entries)

		#expect(analysis.parse.diagnostics.isEmpty)
		#expect(analysis.verdict == .valid)
	}

	/// What used to take all the memory there is: each letter is the next one fifty times, so five lines are 50⁵ symbols
	@Test func lettersThatMultiplyAreAProblemAndNotACrash() {
		var entries: [LogicKeyboardEntry] = []
		for slot in 1 ... 5 {
			let copies = (0 ..< 49).flatMap { _ in [LogicKeyboardEntry.variable(slot + 1), .symbol("∧")] }
			entries += definition(slot, copies + [.variable(slot + 1)])
		}
		entries += [.variable(1), .symbol("∴"), .variable(6)]

		let analysis = LogicChecker.analyze(entries)

		#expect(analysis.parse.diagnostics.map(\.problem) == [.tooLongWrittenOut(limit: LogicParser.maximumWrittenOutLength)])
		#expect(analysis.verdict == nil)
		#expect(LogicEnglish.text(for: analysis.parse, letters: LogicLetters.defaults, descriptors: LogicLetters.emptyDescriptors) == nil)
	}

	@Test func lettersThatDoubleAFewTimesAreFine() {
		var entries: [LogicKeyboardEntry] = []
		for slot in 1 ... 5 {
			entries += definition(slot, [.variable(slot + 1), .symbol("∧"), .variable(slot + 1)])
		}
		entries += [.variable(1), .symbol("∴"), .variable(6)]

		#expect(LogicChecker.analyze(entries).verdict == .valid)
	}

	@Test func aThousandPremisesAreStillChecked() {
		var entries: [LogicKeyboardEntry] = []
		for index in 0 ..< 1000 {
			entries += [.variable(index % 6 + 1), .symbol("→"), .variable((index + 1) % 6 + 1), .delimiter("\n")]
		}
		entries += [.symbol("∴"), .variable(1), .symbol("↔"), .variable(4)]

		#expect(LogicChecker.analyze(entries).verdict == .valid)
	}
}
