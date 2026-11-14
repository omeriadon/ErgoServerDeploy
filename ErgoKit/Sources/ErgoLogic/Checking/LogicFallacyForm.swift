//
//  LogicFallacyForm.swift
//  Ergo
//
//  Created by Adon Omeri on 4/11/2026.
//

import Foundation

/// The shape of a formula, with holes that have to be filled the same way everywhere they appear
indirect enum LogicPattern: Sendable {
	/// Any formula. Different numbers have to be different formulas.
	case formula(Int)

	case not(LogicPattern)
	case and(LogicPattern, LogicPattern)
	case or(LogicPattern, LogicPattern)
	case implies(LogicPattern, LogicPattern)
	case necessarily(LogicPattern)

	/// The number stands for whichever letter the quantifier binds
	case forAll(Int, LogicPattern)
	case exists(Int, LogicPattern)
}

/// A known invalid shape, named by its id in fallacies.json
public struct LogicFallacyForm: Sendable {
	public let fallacyID: String
	let premises: [LogicPattern]
	let conclusion: LogicPattern

	public static func matches(premises: [LogicFormula], conclusion: LogicFormula) -> [LogicFallacyMatch] {
		var matches: [LogicFallacyMatch] = []

		for form in all where !matches.contains(where: { $0.fallacyID == form.fallacyID }) {
			if let used = form.match(premises: premises, conclusion: conclusion) {
				matches.append(LogicFallacyMatch(fallacyID: form.fallacyID, premises: used.sorted()))
			}
		}

		return matches
	}

	/// Extra premises are allowed, the form only has to be in there somewhere
	private func match(premises formulas: [LogicFormula], conclusion formula: LogicFormula) -> [Int]? {
		for bindings in LogicPatternBindings().matching(conclusion, formula) {
			if let used = assign(0, bindings, used: [], formulas: formulas) {
				return used
			}
		}
		return nil
	}

	private func assign(_ index: Int, _ bindings: LogicPatternBindings, used: [Int], formulas: [LogicFormula]) -> [Int]? {
		guard index < premises.count else { return used }

		for (position, formula) in formulas.enumerated() where !used.contains(position) {
			for next in bindings.matching(premises[index], formula) {
				if let result = assign(index + 1, next, used: used + [position], formulas: formulas) {
					return result
				}
			}
		}

		return nil
	}
}

extension LogicFallacyForm {
	private static let a = LogicPattern.formula(0)
	private static let b = LogicPattern.formula(1)
	private static let c = LogicPattern.formula(2)

	public static let all: [LogicFallacyForm] = [
		// A → B, B ∴ A
		LogicFallacyForm(
			fallacyID: "affirming-the-consequent",
			premises: [.implies(a, b), b],
			conclusion: a
		),

		// A → B, ¬A ∴ ¬B
		LogicFallacyForm(
			fallacyID: "denying-the-antecedent",
			premises: [.implies(a, b), .not(a)],
			conclusion: .not(b)
		),

		// A ∨ B, A ∴ ¬B
		LogicFallacyForm(
			fallacyID: "affirming-a-disjunct",
			premises: [.or(a, b), a],
			conclusion: .not(b)
		),

		// ¬(A ∧ B), ¬A ∴ B
		LogicFallacyForm(
			fallacyID: "denying-a-conjunct",
			premises: [.not(.and(a, b)), .not(a)],
			conclusion: b
		),

		// A → B ∴ B → A
		LogicFallacyForm(
			fallacyID: "commutation-of-conditionals",
			premises: [.implies(a, b)],
			conclusion: .implies(b, a)
		),

		// A → B ∴ ¬A → ¬B
		LogicFallacyForm(
			fallacyID: "negating-antecedent-and-consequent",
			premises: [.implies(a, b)],
			conclusion: .implies(.not(a), .not(b))
		),

		// □(A → B), A ∴ □B
		LogicFallacyForm(
			fallacyID: "modal-scope-fallacy",
			premises: [.necessarily(.implies(a, b)), a],
			conclusion: .necessarily(b)
		),

		// □(A → B) ∴ A → □B
		LogicFallacyForm(
			fallacyID: "modal-scope-fallacy",
			premises: [.necessarily(.implies(a, b))],
			conclusion: .implies(a, .necessarily(b))
		),

		// ∀X ∃Y A ∴ ∃Y ∀X A
		LogicFallacyForm(
			fallacyID: "quantifier-shift-fallacy",
			premises: [.forAll(0, .exists(1, a))],
			conclusion: .exists(1, .forAll(0, a))
		),

		// ∀X (A ∨ B) ∴ ∀X A ∨ ∀X B
		LogicFallacyForm(
			fallacyID: "quantifier-shift-fallacy",
			premises: [.forAll(0, .or(a, b))],
			conclusion: .or(.forAll(0, a), .forAll(0, b))
		),

		// ∃X A ∧ ∃X B ∴ ∃X (A ∧ B)
		LogicFallacyForm(
			fallacyID: "quantifier-shift-fallacy",
			premises: [.and(.exists(0, a), .exists(0, b))],
			conclusion: .exists(0, .and(a, b))
		),

		// All A are B ∴ some A are B
		LogicFallacyForm(
			fallacyID: "existential-fallacy",
			premises: [.forAll(0, .implies(a, b))],
			conclusion: .exists(0, .and(a, b))
		),

		// All A are B ∴ all B are A
		LogicFallacyForm(
			fallacyID: "illicit-conversion",
			premises: [.forAll(0, .implies(a, b))],
			conclusion: .forAll(0, .implies(b, a))
		),

		// All A are C, all B are C ∴ all B are A
		LogicFallacyForm(
			fallacyID: "undistributed-middle",
			premises: [.forAll(0, .implies(a, c)), .forAll(0, .implies(b, c))],
			conclusion: .forAll(0, .implies(b, a))
		),
	]
}

private struct LogicPatternBindings {
	var formulas: [Int: LogicFormula] = [:]
	var letters: [Int: Int] = [:]

	/// Every way the pattern fits, more than one when ∧ or ∨ can be read either way round
	func matching(_ pattern: LogicPattern, _ formula: LogicFormula) -> [Self] {
		switch (pattern, formula) {
			case let (.formula(hole), _):
				if let bound = formulas[hole] {
					return bound == formula ? [self] : []
				}

				// Otherwise A → A, A ∴ A would count as affirming the consequent
				guard !formulas.values.contains(formula) else { return [] }

				var next = self
				next.formulas[hole] = formula
				return [next]

			case let (.not(pattern), .not(formula)), let (.necessarily(pattern), .necessarily(formula)):
				return matching(pattern, formula)

			case let (.and(patternLeft, patternRight), .and(left, right)),
			     let (.or(patternLeft, patternRight), .or(left, right)):
				return matching(patternLeft, left).flatMap { $0.matching(patternRight, right) }
					+ matching(patternLeft, right).flatMap { $0.matching(patternRight, left) }

			case let (.implies(patternLeft, patternRight), .implies(left, right)):
				return matching(patternLeft, left).flatMap { $0.matching(patternRight, right) }

			case let (.forAll(hole, pattern), .forAll(slot, formula)),
			     let (.exists(hole, pattern), .exists(slot, formula)):
				guard let next = binding(hole, to: slot) else { return [] }
				return next.matching(pattern, formula)

			default:
				return []
		}
	}

	private func binding(_ hole: Int, to slot: Int) -> Self? {
		if let bound = letters[hole] {
			return bound == slot ? self : nil
		}

		guard !letters.values.contains(slot) else { return nil }

		var next = self
		next.letters[hole] = slot
		return next
	}
}
