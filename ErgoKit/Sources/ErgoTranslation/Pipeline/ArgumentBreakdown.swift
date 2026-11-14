//
//  ArgumentBreakdown.swift
//  ErgoKit
//
//  Created by Adon Omeri on 6/11/2026.
//

import ErgoLogic
import Foundation

/// What the gate and breakdown stages found in some pasted English, which is all the app needs to lay it out as
/// statements joined by links. Nothing is formalized: each statement is translated on its own afterwards.
public struct ArgumentBreakdown: Codable, Hashable, Sendable {
	/// `.argument` when a conclusion was drawn, otherwise `.statements`. Never `.neither`: that's an issue instead.
	public var kind: GateStage.Output.Kind

	/// Each premise, quoted from the text, in order
	public var premises: [String]

	/// The conclusion, quoted from the text, or empty when the text draws none
	public var conclusion: String

	/// The distinct simple claims every premise and the conclusion are built from, in order of first appearance
	public var claims: [BreakdownStage.Output.Claim]

	/// One per letter slot, sanitised: the board's own descriptors kept as they were, and each new claim in a free slot.
	/// A claim that matched an existing descriptor reuses its slot, so formalizing a statement later gives it the same letter.
	public var descriptors: [String]

	/// An error when the English wasn't worth breaking down, in which case everything above is empty
	/// (descriptors are the board's own, untouched)
	public var issues: [TranslationIssue]

	public init(
		kind: GateStage.Output.Kind,
		premises: [String] = [],
		conclusion: String = "",
		claims: [BreakdownStage.Output.Claim] = [],
		descriptors: [String] = LogicLetters.emptyDescriptors,
		issues: [TranslationIssue] = []
	) {
		self.kind = kind
		self.premises = premises
		self.conclusion = conclusion
		self.claims = claims
		self.descriptors = descriptors
		self.issues = issues
	}
}
