//
//  EnglishValidatorTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoTranslation
import Testing

/// Local validation turns gibberish away before any model call
struct EnglishValidatorTests {
	@Test func turnsAwayGibberish() {
		#expect(EnglishValidator.problem(with: "  ") != nil)
		#expect(EnglishValidator.problem(with: "→∧¬ ∨∨ ()") != nil)
		#expect(EnglishValidator.problem(with: "hello") != nil)
		#expect(EnglishValidator.problem(with: String(repeating: "word ", count: EnglishValidator.characterLimit / 5 + 1)) != nil)
	}

	@Test func acceptsSentences() {
		#expect(EnglishValidator.problem(with: "If it rains, the ground gets wet. It rained, so the ground is wet.") == nil)
	}
}
