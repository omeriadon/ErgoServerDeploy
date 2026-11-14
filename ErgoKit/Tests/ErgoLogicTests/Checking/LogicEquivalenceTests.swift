//
//  LogicEquivalenceTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoLogic
import Testing

struct LogicEquivalenceTests {
	let vocabulary = LogicInputVocabulary(letters: LogicLetters.defaults)

	func argument(_ text: String) -> LogicArgument {
		let parse = LogicParser.parse(vocabulary.entries(in: text))
		#expect(parse.diagnostics.isEmpty, "Doesn't parse: \(text)")
		return parse.argument
	}

	func formula(_ text: String) -> LogicFormula {
		argument(text).premises[0].formula
	}

	@Test func renamesLetters() {
		#expect(LogicEquivalence.mapping(from: argument("X→Y,X∴Y"), to: argument("P→Q,P∴Q")) == [1: 4, 2: 5])
	}

	@Test func equivalentFormulas() {
		#expect(LogicEquivalence.equivalent(formula("X∨Y"), formula("¬X→Y")) == true)
		#expect(LogicEquivalence.equivalent(formula("¬(X∧Y)"), formula("¬X∨¬Y")) == true)
		#expect(LogicEquivalence.equivalent(formula("X⊕Y"), formula("¬(X↔Y)")) == true)
	}

	@Test func conversesArentEquivalent() {
		#expect(LogicEquivalence.equivalent(formula("X→Y"), formula("Y→X")) == false)
		#expect(LogicEquivalence.mapping(from: argument("X→Y,X∴Y"), to: argument("X→Y,Y∴X")) == nil)
	}

	/// Renaming X and Y the other way round makes them the same, so that isn't enough to tell them apart
	@Test func renamingCanMakeConversesMatch() {
		#expect(LogicEquivalence.mapping(from: argument("X→Y"), to: argument("Y→X")) == [1: 2, 2: 1])
	}

	@Test func premiseOrderDoesntMatter() {
		#expect(LogicEquivalence.mapping(from: argument("X→Y,X∴Y"), to: argument("X,X→Y∴Y")) != nil)
		#expect(LogicEquivalence.mapping(from: argument("X∨Y,¬X∴Y"), to: argument("¬P,¬P→Q∴Q")) == [1: 4, 2: 5])
	}

	@Test func premiseCountsHaveToMatch() {
		#expect(LogicEquivalence.mapping(from: argument("X→Y,X∴Y"), to: argument("X→Y,X,X∴Y")) == nil)
		#expect(LogicEquivalence.mapping(from: argument("X∧Y∴Y"), to: argument("X,Y∴Y")) == nil)
	}

	@Test func conclusionsHaveToMatch() {
		#expect(LogicEquivalence.mapping(from: argument("X→Y,X∴Y"), to: argument("X→Y,X")) == nil)
		#expect(LogicEquivalence.mapping(from: argument("X→Y,X∴Y"), to: argument("X→Y,X∴X")) == nil)
	}

	@Test func onlyPropositionalLogicIsCompared() {
		#expect(LogicEquivalence.equivalent(formula("□X"), formula("□X")) == nil)
		#expect(LogicEquivalence.mapping(from: argument("∀XP(X)∴P(Y)"), to: argument("∀XP(X)∴P(Y)")) == nil)
	}
}
