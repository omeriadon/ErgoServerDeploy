//
//  LogicParse.swift
//  Ergo
//
//  Created by Adon Omeri on 8/11/2026.
//

import Foundation

/// Premises are separated by commas or new lines. The conclusion comes after ∴, ⊢ or ⊨,
/// or before ∵. Without any of those every line is checked on its own.
///
/// Binding, tightest first: ¬ □ ◇ ∀ ∃, then ∧, then ∨ ⊕, then → (groups right), then ↔ ⇔.
public struct LogicArgument: Equatable, Sendable {
	public var premises: [LogicStatement] = []
	public var conclusion: LogicStatement?

	public init(premises: [LogicStatement] = [], conclusion: LogicStatement? = nil) {
		self.premises = premises
		self.conclusion = conclusion
	}
}

public struct LogicStatement: Equatable, Sendable {
	public let formula: LogicFormula

	/// Entry indices in the editor
	public let range: Range<Int>

	public init(formula: LogicFormula, range: Range<Int>) {
		self.formula = formula
		self.range = range
	}
}

public struct LogicDiagnostic: Equatable, Sendable, Error {
	public let problem: LogicProblem

	/// Entry indices in the editor, so it can be underlined later
	public let range: Range<Int>

	/// The text just stops partway through, which is probably still being typed rather than a mistake
	public var isUnfinished = false

	/// A likely fix, when the mistake is easy to guess
	public var fix: LogicFix?

	public init(problem: LogicProblem, range: Range<Int>, isUnfinished: Bool = false, fix: LogicFix? = nil) {
		self.problem = problem
		self.range = range
		self.isUnfinished = isUnfinished
		self.fix = fix
	}
}

/// Swaps `range` for `replacement`, in entry indices
public struct LogicFix: Equatable, Sendable {
	public let range: Range<Int>
	public let replacement: [LogicKeyboardEntry]

	public init(range: Range<Int>, replacement: [LogicKeyboardEntry]) {
		self.range = range
		self.replacement = replacement
	}
}

public enum LogicProblem: Equatable, Sendable {
	case expectedFormula(after: LogicKeyboardEntry?)
	case missingConnective(before: LogicKeyboardEntry)
	case unexpected(LogicKeyboardEntry)
	case unclosed(LogicKeyboardEntry)
	case mismatched(open: LogicKeyboardEntry, close: LogicKeyboardEntry)
	case expectedLetter(after: LogicKeyboardEntry)

	/// A set term like X∪Y standing where a statement should be. Carries the ∪, ∩ or ∅ that made it a set.
	case setWithoutRelation(LogicKeyboardEntry)

	case extraArgumentMarker(LogicKeyboardEntry)
	case missingConclusion(marker: LogicKeyboardEntry)
	case extraConclusions(marker: LogicKeyboardEntry)
	case misplacedEndMarker

	/// Something other than one letter before ≔
	case definitionNeedsLetter
	case definitionAsConclusion
	case redefined(letter: Int)
	case circularDefinition(letter: Int)

	/// Sets hold members, never other sets
	case usedAsSetAndMember(letter: Int)
	case setAsMember

	/// Brackets and ¬ □ ◇ ∀ ∃ inside one another further than anything checks
	case tooDeep(limit: Int)

	/// One statement of more symbols than anything checks
	case tooLong(limit: Int)

	/// Short as written, but letters standing for letters make it this long once each is written out
	case tooLongWrittenOut(limit: Int)
}

public struct LogicParse: Equatable, Sendable {
	public var argument = LogicArgument()
	public var diagnostics: [LogicDiagnostic] = []

	/// The marker that split premises from the conclusion, if any
	public var marker: LogicKeyboardEntry?

	public var definitions: [LogicDefinition] = []

	/// Ends with ∎
	public var hasEndMarker = false
}
