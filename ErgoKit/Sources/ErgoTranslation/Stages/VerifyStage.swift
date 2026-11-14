//
//  VerifyStage.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import Foundation

/// Compares the original English with the logic read back as English
public enum VerifyStage: TranslationStage {
	public static let name = "verify"

	public struct Input: Codable, Sendable {
		public let english: String

		/// `LogicEnglish.text`, which is exact
		public let reading: String

		public init(english: String, reading: String) {
			self.english = english
			self.reading = reading
		}
	}

	public struct Output: Codable, Sendable {
		public let matches: Bool
		public let differences: [String]

		/// The premises or conclusion themselves are wrong, split or merged or missing, so rewriting the formulas can't help
		public let structural: Bool

		public init(matches: Bool, differences: [String], structural: Bool = false) {
			self.matches = matches
			self.differences = differences
			self.structural = structural
		}

		private enum CodingKeys: String, CodingKey {
			case matches, differences, structural
		}

		public init(from decoder: any Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			matches = try container.decode(Bool.self, forKey: .matches)
			differences = try container.decode([String].self, forKey: .differences)
			structural = try container.decodeIfPresent(Bool.self, forKey: .structural) ?? false
		}
	}

	public static let outputSchema = JSONSchema.object([
		.init("matches", .boolean(description: "Whether the reading claims exactly what the original does, nothing more and nothing less")),
		.init("differences", .array(.string(), description: "Each difference in meaning, short, in the style of a compiler error")),
		.init("structural", .boolean(description: "Whether a difference is premises or a conclusion that are split, merged, missing or extra, rather than how a formula is written")),
	])
}
