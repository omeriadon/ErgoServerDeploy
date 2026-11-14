//
//  BreakdownStage.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import Foundation

/// Finds the premises, the conclusion, and the simple claims they're built from
public enum BreakdownStage: TranslationStage {
	public static let name = "breakdown"

	public struct Input: Codable, Sendable {
		public let english: String
		public let maximumClaims: Int
		public let descriptorWordLimit: Int

		/// What the board already calls its claims, other statements' labels included. A claim that means the same
		/// as one of these takes its text as its descriptor, so the claim keeps its letter. Missing when the board has none.
		public let descriptors: [String]?

		/// The last breakdown, when reading its logic back showed it split the text wrongly. Missing on the first try.
		public let previous: Output?

		/// What was wrong with `previous`. Missing on the first try.
		public let problems: [String]?

		public init(
			english: String,
			maximumClaims: Int,
			descriptorWordLimit: Int,
			descriptors: [String]? = nil,
			previous: Output? = nil,
			problems: [String]? = nil
		) {
			self.english = english
			self.maximumClaims = maximumClaims
			self.descriptorWordLimit = descriptorWordLimit
			self.descriptors = descriptors
			self.previous = previous
			self.problems = problems
		}
	}

	public struct Output: Codable, Sendable {
		public struct Claim: Codable, Sendable, Hashable {
			public let meaning: String
			public let descriptor: String

			public init(meaning: String, descriptor: String) {
				self.meaning = meaning
				self.descriptor = descriptor
			}
		}

		public let premises: [String]
		public let conclusion: String
		public let claims: [Claim]

		public init(premises: [String], conclusion: String, claims: [Claim]) {
			self.premises = premises
			self.conclusion = conclusion
			self.claims = claims
		}
	}

	public static let outputSchema = JSONSchema.object([
		.init("premises", .array(.string(), maxItems: 12, description: "Each premise, quoted from the text")),
		.init("conclusion", .string(description: "The conclusion, quoted from the text, or empty when there isn't one")),
		.init("claims", .array(
			.object([
				.init("meaning", .string(description: "The claim as a short positive sentence, with no not, and, or, if")),
				.init("descriptor", .string(description: "A label for the claim of at most four words")),
			]),
			maxItems: 6,
			description: "The distinct simple claims every premise and the conclusion are built from"
		)),
	])
}
