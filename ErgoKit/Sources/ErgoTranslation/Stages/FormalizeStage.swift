//
//  FormalizeStage.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import Foundation

/// Writes each premise and the conclusion in the app's symbols
public enum FormalizeStage: TranslationStage {
	public static let name = "formalize"

	public struct Input: Codable, Sendable {
		public struct Letter: Codable, Sendable {
			public let letter: String
			public let meaning: String

			public init(letter: String, meaning: String) {
				self.letter = letter
				self.meaning = meaning
			}
		}

		public let english: String
		public let premises: [String]
		public let conclusion: String?
		public let letters: [Letter]

		/// The letters the board already names, as `letter` and `meaning` (its descriptor), whichever statement uses them.
		/// A claim in `letters` that is also here keeps that letter, and no other claim may take a letter listed here.
		/// Missing when the board names none, or the request carried no descriptors.
		public let descriptors: [Letter]?

		/// `LogicGrammar.reference`
		public let grammar: String
		public let grammarVersion: Int

		/// The last try and what was wrong with it, compiler errors or differences in meaning
		public let previous: Output?
		public let problems: [String]

		public init(
			english: String,
			premises: [String],
			conclusion: String?,
			letters: [Letter],
			descriptors: [Letter]? = nil,
			grammar: String,
			grammarVersion: Int,
			previous: Output?,
			problems: [String]
		) {
			self.english = english
			self.premises = premises
			self.conclusion = conclusion
			self.letters = letters
			self.descriptors = descriptors
			self.grammar = grammar
			self.grammarVersion = grammarVersion
			self.previous = previous
			self.problems = problems
		}
	}

	public struct Output: Codable, Sendable {
		public let premises: [String]
		public let conclusion: String

		public init(premises: [String], conclusion: String) {
			self.premises = premises
			self.conclusion = conclusion
		}
	}

	public static let outputSchema = JSONSchema.object([
		.init("premises", .array(.string(), description: "One formula per premise, in order, using only the given letters and symbols")),
		.init("conclusion", .string(description: "The conclusion as a formula, or empty when there isn't one")),
	])
}
