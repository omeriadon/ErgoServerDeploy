//
//  LogicProver.swift
//  ErgoKit
//
//  Created by Adon Omeri on 7/11/2026.
//

import Foundation

/// Decides everything a truth table can't: □ ◇, ∀ ∃, identity and sets, in any mix. A semantic tableau: it tries to
/// build a situation where the given statements hold. If every attempt contradicts itself, no such situation exists.
/// If one finishes, it's a real model. Neither answer is ever a guess, and running out of steps says so instead.
///
/// - □ ◇ are S5: every possible world can see every other.
/// - Things exist in every world, there's always at least one, and a letter names the same thing in every world.
/// - A set is the things that are in it, which can differ between worlds. Sets hold things, never other sets.
struct LogicProver {
	enum Outcome: Equatable {
		case impossible
		case possible
		case unknown
	}

	/// Counts work rather than time, so the same logic always gets the same answer
	static let stepLimit = 3_000_000

	/// Letters from here up are ∀ and ∃'s own
	static let firstBound = 1000

	/// Letters from here up are things made up during the search
	static let firstMadeUp = 1_000_000

	/// Everything being checked together, so a letter is the same sort in all of it
	let context: [LogicFormula]

	/// Whether there's a situation where all of `truths` hold and all of `falsehoods` don't
	func check(truths: [LogicFormula], falsehoods: [LogicFormula] = []) -> Outcome {
		var sorts = LogicSorts()
		var next = Self.firstBound

		func bound(_ formula: LogicFormula) -> LogicFormula {
			let formula = formula.uniquelyBound(next: &next, sorts: &sorts)
			sorts.add(formula)
			return formula
		}

		context.forEach { _ = bound($0) }
		let (truths, falsehoods) = (truths.map(bound), falsehoods.map(bound))
		guard sorts.conflict == nil else { return .unknown }

		var translator = Translator(sorts: sorts, firstBound: Self.firstBound, nextMadeUp: Self.firstMadeUp)

		do {
			let positive = try truths.map { try translator.translate($0, positive: true) }
			let negative = try falsehoods.map { try translator.translate($0, positive: false) }
			let formulas = (positive + negative).map(\.miniscoped)

			var search = Search(firstMadeUp: Self.firstMadeUp, stepLimit: Self.stepLimit)
			search.maximumThings = Self.smallModelBound(of: formulas)
			return try search.isPossible(formulas) ? .possible : .impossible
		} catch {
			return .unknown
		}
	}

	/// With only one-place predicates and no □ ◇, anything possible is possible with at most q·2^k things
	/// (Löwenheim–Behmann), for k predicates and q quantifiers and names. Searching that far is a full answer.
	static func smallModelBound(of formulas: [Node]) -> Int? {
		var measure = Measure()
		formulas.forEach { measure.add($0) }

		guard measure.isMonadic, measure.predicates.count <= 16 else { return nil }
		return max(1, measure.quantifiers + measure.names.count) << measure.predicates.count
	}
}
