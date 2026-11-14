//
//  LogicEnglishTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoLogic
import Testing

/// Reading logic back is exact: compound parts are bracketed, ∧ and ∨ chains are flattened
struct LogicEnglishTests {
	let letters = LogicLetters.defaults
	let vocabulary = LogicInputVocabulary(letters: LogicLetters.defaults)

	func read(_ text: String, descriptors: [String] = LogicLetters.emptyDescriptors) -> String {
		let parse = LogicParser.parse(vocabulary.entries(in: text))
		#expect(parse.diagnostics.isEmpty, "Doesn't parse: \(text)")
		return LogicEnglish.text(for: parse.argument, letters: letters, descriptors: descriptors)
	}

	@Test func descriptorsReadAsClaims() {
		let weather = ["it rains", "the ground is wet", "", "", "", ""]
		#expect(read("X→Y,X∴Y", descriptors: weather) == "If it rains, then the ground is wet.\nIt rains.\nTherefore, the ground is wet.")
	}

	@Test func compoundPartsAreBracketed() {
		#expect(read("¬(X∧Y)") == "It is not the case that (X and Y).")
		#expect(read("¬X") == "It is not the case that X.")
		#expect(read("X∧Y∨Z") == "(X and Y) or Z.")
		#expect(read("X→(Y→Z)") == "If X, then (if Y, then Z).")
		#expect(read("¬X∧Y") == "(It is not the case that X) and Y.")
		#expect(read("X⊕Y") == "Either X or Y, but not both.")
		#expect(read("∀XP(X)") == "For every X, P(X).")
		#expect(read("X∪Y⊂Z") == "(The union of X and Y) is a proper subset of Z.")
	}

	@Test func chainsAreFlattened() {
		#expect(read("X∧Y∧Z") == "X, Y and Z.")
		#expect(read("X∧(Y∧Z)") == "X, Y and Z.")
	}

	@Test func statementsWithoutAConclusion() {
		#expect(read("X\nY") == "X.\nY.")
	}

	/// One argument per thing the keyboard can write, so a new key has to be added here
	static let everyEntry: [(entry: LogicKeyboardEntry, logic: String, english: String)] = [
		(.symbol("¬"), "¬X", "It is not the case that X."),
		(.symbol("∧"), "X∧Y", "X and Y."),
		(.symbol("∨"), "X∨Y", "X or Y."),
		(.symbol("→"), "X→Y", "If X, then Y."),
		(.symbol("↔"), "X↔Y", "X if and only if Y."),
		(.symbol("⇔"), "X⇔Y", "X if and only if Y."),
		(.symbol("⊕"), "X⊕Y", "Either X or Y, but not both."),
		(.symbol("⊤"), "⊤", "True."),
		(.symbol("∀"), "∀XP(X)", "For every X, P(X)."),
		(.symbol("∃"), "∃XP(X)", "For some X, P(X)."),
		(.symbol("□"), "□X", "Necessarily, X."),
		(.symbol("◇"), "◇X", "Possibly, X."),
		(.symbol("="), "X=Y", "X equals Y."),
		(.symbol("≠"), "X≠Y", "X does not equal Y."),
		(.symbol("∈"), "X∈Y", "X is a member of Y."),
		(.symbol("∉"), "X∉Y", "X is not a member of Y."),
		(.symbol("⊂"), "X⊂Y", "X is a proper subset of Y."),
		(.symbol("⊆"), "X⊆Y", "X is a subset of Y."),
		(.symbol("∪"), "X∪Y=Z", "(The union of X and Y) equals Z."),
		(.symbol("∩"), "X∩Y=Z", "(The intersection of X and Y) equals Z."),
		(.symbol("∅"), "X=∅", "X equals the empty set."),
		(.symbol("∴"), "X∴Y", "X.\nTherefore, Y."),
		(.symbol("∵"), "Y∵X", "X.\nTherefore, Y."),
		(.symbol("⊢"), "X⊢Y", "X.\nThis proves that Y."),
		(.symbol("⊨"), "X⊨Y", "X.\nThis entails that Y."),
		(.symbol("≔"), "X≔Y", "X is defined as Y."),
		(.symbol("∎"), "X∴Y\n∎", "X.\nTherefore, Y.\nThis completes the proof."),
		(.delimiter("("), "¬(X∧Y)", "It is not the case that (X and Y)."),
		(.delimiter(")"), "(X)", "X."),
		(.delimiter("["), "¬[X∧Y]", "It is not the case that (X and Y)."),
		(.delimiter("]"), "[X]", "X."),
		(.delimiter(","), "X,Y", "X.\nY."),
		(.delimiter("\n"), "X\nY", "X.\nY."),
	]

	@Test func everyKeyIsCovered() {
		#expect(Set(Self.everyEntry.map(\.entry)) == Set(LogicKeyboardEntry.symbolEntries))
	}

	@Test(arguments: everyEntry)
	func everyKeyReads(entry _: LogicKeyboardEntry, logic: String, english: String) {
		#expect(reading(logic) == english)
	}

	func reading(_ text: String, descriptors: [String] = LogicLetters.emptyDescriptors) -> String? {
		LogicEnglish.text(for: LogicParser.parse(vocabulary.entries(in: text)), letters: letters, descriptors: descriptors)
	}

	@Test func definitionsReadInTheirPlace() {
		#expect(reading("X≔Y∧Z") == "X is defined as (Y and Z).")
		#expect(reading("Z≔X∪Y") == "Z is defined as (the union of X and Y).")
		#expect(reading("X≔Y\nX∴Y") == "X is defined as Y.\nX.\nTherefore, Y.")
		#expect(reading("X≔Y", descriptors: ["it rains", "", "", "", "", ""]) == "It rains is defined as Y.")
	}

	@Test func halfWrittenLogicHasNoReading() {
		for text in ["X→", "(X", "X≔", "≔X", "X∪", "X∴"] {
			#expect(reading(text) == nil, "Read: \(text)")
		}
	}
}
