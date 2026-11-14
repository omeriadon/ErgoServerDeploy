//
//  GateStage.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import Foundation

/// Is this logic at all?
public enum GateStage: TranslationStage {
	public static let name = "gate"

	public struct Input: Codable, Sendable {
		public let english: String

		public init(english: String) {
			self.english = english
		}
	}

	public struct Output: Codable, Sendable {
		public enum Kind: String, Codable, Sendable, CaseIterable {
			/// Premises leading to a conclusion
			case argument

			/// Claims with no conclusion drawn
			case statements

			/// Questions, commands, gibberish, anything that isn't a claim
			case neither
		}

		public let kind: Kind
		public let reason: String

		public init(kind: Kind, reason: String) {
			self.kind = kind
			self.reason = reason
		}
	}

	public static let outputSchema = JSONSchema.object([
		.init("kind", .string(
			enum: Output.Kind.allCases.map(\.rawValue),
			description: "argument if premises lead to a conclusion, statements if it only makes claims, neither for anything else"
		)),
		.init("reason", .string(description: "When kind is neither, a short reason in the style of a compiler error, otherwise empty")),
	])
}
