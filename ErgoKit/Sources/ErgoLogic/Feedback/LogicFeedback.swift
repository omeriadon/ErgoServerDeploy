//
//  LogicFeedback.swift
//  Ergo
//
//  Created by Adon Omeri on 5/11/2026.
//

import Foundation

/// The one thing worth saying about what's in the editor
public enum LogicFeedback: Equatable, Sendable {
	/// The text stops partway through, so it's probably still being typed
	case unfinished(LogicDiagnostic)

	/// The first thing that doesn't parse
	case error(LogicDiagnostic)

	/// The premises can't all be true at once, so the argument is valid for an empty reason
	case contradictoryPremises

	/// Valid, but only because the conclusion is one of the premises
	case circular(premise: Int)

	case valid

	/// `fallacy` is nil when it doesn't match any named form
	case invalid(counterexample: [Int: Bool], fallacy: LogicFallacyMatch?)

	/// Couldn't be proved either way
	case unchecked(fallacy: LogicFallacyMatch?)

	/// No conclusion, so each statement on its own
	case statuses([LogicStatus])
}

public extension LogicAnalysis {
	/// Nil when there's nothing to say
	var feedback: LogicFeedback? {
		let diagnostics = parse.diagnostics
		if let error = diagnostics.filter({ !$0.isUnfinished }).min(by: { $0.range.lowerBound < $1.range.lowerBound }) {
			return .error(error)
		}
		if let unfinished = diagnostics.first {
			return .unfinished(unfinished)
		}

		guard let verdict else {
			return statuses.isEmpty ? nil : .statuses(statuses)
		}

		switch verdict {
			case .valid:
				if warnings.contains(.inconsistentPremises) {
					return .contradictoryPremises
				}
				for case let .circular(premise) in warnings {
					return .circular(premise: premise)
				}
				return .valid

			case let .invalid(counterexample):
				return .invalid(counterexample: counterexample, fallacy: fallacies.first { $0.fallacyID != "non-sequitur" })

			case .undecided:
				return .unchecked(fallacy: fallacies.first)
		}
	}
}

/// Worded like compiler diagnostics: what's expected or wrong, quoting the glyph, no full stops
extension LogicProblem {
	public func message(letters: [String]) -> String {
		let glyph = { (entry: LogicKeyboardEntry) in Self.glyph(entry, letters: letters) }

		return switch self {
			case .expectedFormula(after: .delimiter("(")), .expectedFormula(after: .delimiter("[")):
				"Expected statement inside brackets"
			case let .expectedFormula(after: entry?):
				"Expected statement after \(glyph(entry))"
			case .expectedFormula(after: nil):
				"Expected statement"
			case let .missingConnective(before: entry):
				"Expected connective before \(glyph(entry))"
			case let .unexpected(entry) where entry == .delimiter(")") || entry == .delimiter("]"):
				"Unmatched \(glyph(entry))"
			case .unexpected(.symbol("∪")), .setWithoutRelation(.symbol("∪")):
				"'∪' is set union, not 'or'"
			case .unexpected(.symbol("∩")), .setWithoutRelation(.symbol("∩")):
				"'∩' is set intersection, not 'and'"
			case .setWithoutRelation:
				"'∅' is a set, not a statement"
			case let .unexpected(entry) where entry == .symbol("=") || entry == .symbol("≠"):
				"\(glyph(entry)) compares letters, not statements"
			case let .unexpected(entry) where [.symbol("∈"), .symbol("∉"), .symbol("⊂"), .symbol("⊆")].contains(entry):
				"Expected letter before \(glyph(entry))"
			case let .unexpected(entry) where Self.connectives.contains(entry):
				"Expected statement before \(glyph(entry))"
			case .unexpected(.delimiter(",")):
				"',' can't appear inside brackets"
			case let .unexpected(entry):
				"Unexpected \(glyph(entry))"
			case let .unclosed(entry):
				"Expected \(glyph(Self.closer(for: entry))) to close \(glyph(entry))"
			case let .mismatched(open, close):
				"Expected \(glyph(Self.closer(for: open))) to close \(glyph(open)), found \(glyph(close))"
			case let .expectedLetter(after: entry):
				"Expected letter after \(glyph(entry))"
			case let .extraArgumentMarker(entry):
				"Duplicate \(glyph(entry))"
			case .missingConclusion(.symbol("∵")):
				"Expected conclusion before '∵'"
			case let .missingConclusion(marker):
				"Expected conclusion after \(glyph(marker))"
			case .extraConclusions(.symbol("∵")):
				"Expected one conclusion before '∵'"
			case let .extraConclusions(marker):
				"Expected one conclusion after \(glyph(marker))"
			case .misplacedEndMarker:
				"'∎' must come last"
			case let .usedAsSetAndMember(letter):
				"\(glyph(.variable(letter))) is used as both a set and a member"
			case .setAsMember:
				"Expected a member, found a set"
			case .definitionNeedsLetter:
				"Expected one letter before '≔'"
			case .definitionAsConclusion:
				"Expected a statement as the conclusion, found a definition"
			case let .redefined(letter):
				"\(glyph(.variable(letter))) is already defined"
			case let .circularDefinition(letter):
				"\(glyph(.variable(letter))) is defined in terms of itself"
			case let .tooDeep(limit):
				"Expected at most \(limit) levels of nesting"
			case let .tooLong(limit):
				"Expected a statement of at most \(limit) symbols"
			case let .tooLongWrittenOut(limit):
				"Expected at most \(limit) symbols once every letter is written out"
		}
	}

	/// A note under the message, only when there's something the message doesn't already say
	public func advice(letters: [String]) -> String? {
		switch self {
			case .missingConnective:
				"Join statements with ∧, ∨, → or ↔"
			case .unexpected(.symbol("∪")), .unexpected(.symbol("∩")), .setWithoutRelation:
				"To compare sets, add = or ⊂"
			case .unexpected(.symbol("=")):
				"Use ↔ for 'if and only if'"
			case .unexpected(.symbol("≠")):
				"Use ⊕ for 'exclusive or'"
			case .unexpected(.delimiter(",")):
				"Commas separate premises"
			case .usedAsSetAndMember, .setAsMember:
				"Sets hold members, never other sets"
			case .definitionAsConclusion:
				"Move the definition before the premises"
			case .tooLong:
				"Split it into premises, or give part of it a letter with ≔"
			case .tooLongWrittenOut:
				"A letter that stands for other letters is as long as all of them together"
			case .extraArgumentMarker:
				"An argument has one marker, between the premises and the conclusion"
			case .extraConclusions(.symbol("∵")):
				"Move the other statements after '∵' as premises"
			case let .extraConclusions(marker):
				"Move the other statements before \(Self.glyph(marker, letters: letters)) as premises"
			default:
				nil
		}
	}

	private static let connectives: [LogicKeyboardEntry] = ["∧", "∨", "⊕", "→", "↔", "⇔"].map { .symbol($0) }

	private static func closer(for open: LogicKeyboardEntry) -> LogicKeyboardEntry {
		open == .delimiter("[") ? .delimiter("]") : .delimiter(")")
	}

	/// Quoted, the way a compiler quotes a token
	private static func glyph(_ entry: LogicKeyboardEntry, letters: [String]) -> String {
		entry == .delimiter("\n") ? "new line" : "'\(entry.glyph(letters: letters))'"
	}
}
