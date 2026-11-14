//
//  LogicEditorTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoLogic
import Foundation
import Testing

/// Entries, alternates, slots surviving letter changes, lenient paste, and letter validation
struct LogicEditorTests {
	let letters = LogicLetters.defaults
	let vocabulary = LogicInputVocabulary(letters: LogicLetters.defaults)

	@Test func everyEntryIsOneUTF16Unit() {
		for entry in LogicKeyboardEntry.variables + LogicKeyboardEntry.symbolEntries {
			let glyph = entry.glyph(letters: letters)
			#expect(glyph.utf16.count == 1, "Entries have to be one UTF-16 unit: \(glyph)")
			#expect(vocabulary.accepts(glyph))
			#expect(vocabulary.entry(for: Character(glyph)) == entry)
		}
	}

	@Test func acceptsOnlyKeyboardText() {
		#expect(vocabulary.accepts(""))
		#expect(vocabulary.accepts("X∧Y→(P∨Q),\nR≠X"))
		for invalid in ["A", "X A", "X1", "X🙂", "X\u{FFFC}", "X\t", "X⊥", "X∧́", "X\r", "x"] {
			#expect(!vocabulary.accepts(invalid), "Accepted invalid input: \(invalid)")
		}
	}

	@Test func pasteIsLenient() {
		#expect(vocabulary.entries(in: "x ∧ y!") == [.variable(1), .symbol("∧"), .variable(2)])
		#expect(vocabulary.normalized("p→q") == "P→Q")
	}

	@Test func slotsSurviveLetterChanges() {
		let entries = vocabulary.entries(in: "X∧Y")
		let swapped = LogicInputVocabulary(letters: ["A", "B", "C", "D", "E", "F"])
		#expect(swapped.text(for: entries) == "A∧B")
		#expect(swapped.entries(in: "A∧B") == entries)
	}

	@Test func lettersResolveToSixDistinctLetters() {
		#expect(LogicLetters.resolved([]) == LogicLetters.defaults)
		#expect(LogicLetters.resolved(["A", "A", "🙂", "", "AB", "é", "G"]) == ["A", "Y", "Z", "P", "Q", "R"])
		#expect(LogicLetters.resolved(["Y", "X", "Z", "P", "Q", "R"]) == ["Y", "X", "Z", "P", "Q", "R"])
		#expect(LogicLetters.resolved(["Y", "Y", "X", "P", "Q", "R"]) == ["Y", "A", "X", "P", "Q", "R"])
		#expect(Set(LogicLetters.resolved(["x", "X", "x", "X", "x", "X"]).map { $0.uppercased() }).count == 6)
	}

	@Test func letterProblems() {
		#expect(LogicLetters.problem(with: "A", in: 1, of: letters) == nil)
		#expect(LogicLetters.problem(with: "x", in: 1, of: letters) == nil)
		#expect(LogicLetters.problem(with: "y", in: 1, of: letters) == .alreadyUsed)
		#expect(LogicLetters.problem(with: "1", in: 1, of: letters) == .notALetter)
		#expect(LogicLetters.problem(with: "é", in: 1, of: letters) == .notALetter)
		#expect(LogicLetters.problem(with: "AB", in: 1, of: letters) == .notALetter)
	}

	@Test func entriesAndAlternates() {
		#expect(vocabulary.entry(for: "∧") == .symbol("∧"))
		#expect(vocabulary.entry(for: "(") == .delimiter("("))
		#expect(vocabulary.entry(for: "X") == .variable(1))
		#expect(LogicKeyboardEntry.symbol("=").alternate == .symbol("≠"))
	}

	/// Boards saved before ErgoKit existed have to keep decoding, so this is the synthesized format as it was then
	@Test func savedEntriesStillDecode() throws {
		let saved = #"[{"variable":{"_0":1}},{"symbol":{"_0":"→"}},{"delimiter":{"_0":"("}},{"variable":{"_0":6}},{"delimiter":{"_0":"\n"}},{"symbol":{"_0":"∴"}}]"#
		let entries: [LogicKeyboardEntry] = [.variable(1), .symbol("→"), .delimiter("("), .variable(6), .delimiter("\n"), .symbol("∴")]

		#expect(try JSONDecoder().decode([LogicKeyboardEntry].self, from: Data(saved.utf8)) == entries)
		#expect(try String(decoding: JSONEncoder().encode(entries), as: UTF8.self) == saved)
	}
}
