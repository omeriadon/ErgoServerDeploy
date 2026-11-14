//
//  LogicEquivalence.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import Foundation

/// Whether two pieces of logic say the same thing, so a translation can be graded on meaning rather than spelling
public enum LogicEquivalence {
	/// Whether two arguments say the same thing, allowing the letters to be renamed:
	/// some one-to-one mapping of `a`'s letters onto `b`'s makes every premise equivalent to exactly one premise (any order)
	/// and the conclusions equivalent. Keyed by `a`'s slots.
	///
	/// Nil when there's no such mapping, or when either uses something the checker can't evaluate.
	public static func mapping(from a: LogicArgument, to b: LogicArgument) -> [Int: Int]? {
		let formulas = a.formulas + b.formulas
		guard formulas.allSatisfy(\.isPropositional),
		      a.premises.count == b.premises.count,
		      (a.conclusion == nil) == (b.conclusion == nil)
		else { return nil }

		let source = a.formulas.reduce(into: Set<Int>()) { $0.formUnion($1.slots) }.sorted()
		let target = b.formulas.reduce(into: Set<Int>()) { $0.formUnion($1.slots) }

		// `b`'s own letters first, so the mapping found is the natural one
		let candidates = target.sorted() + LogicLetters.slots.filter { !target.contains($0) }

		func search(_ index: Int, _ mapping: [Int: Int]) -> [Int: Int]? {
			guard index < source.count else {
				return matches(a.renamed(mapping), b) ? mapping : nil
			}

			let used = Set(mapping.values)
			for slot in candidates where !used.contains(slot) {
				var next = mapping
				next[source[index]] = slot
				if let found = search(index + 1, next) {
					return found
				}
			}
			return nil
		}

		return search(0, [:])
	}

	/// Same truth value on every row, letters as written. Nil when either isn't propositional.
	public static func equivalent(_ a: LogicFormula, _ b: LogicFormula) -> Bool? {
		guard a.isPropositional, b.isPropositional else { return nil }

		let table = TruthTable([a, b])
		guard table.fits else { return nil }
		return table.rows.allSatisfy { table.evaluate(a, row: $0) == table.evaluate(b, row: $0) }
	}

	/// Equivalence is transitive, so taking the first unused match never blocks a later premise
	private static func matches(_ a: LogicArgument, _ b: LogicArgument) -> Bool {
		if let left = a.conclusion?.formula, let right = b.conclusion?.formula, equivalent(left, right) != true {
			return false
		}

		var unused = b.premises.map(\.formula)
		for premise in a.premises {
			guard let match = unused.firstIndex(where: { equivalent(premise.formula, $0) == true }) else {
				return false
			}
			unused.remove(at: match)
		}
		return true
	}
}

private extension LogicArgument {
	var formulas: [LogicFormula] {
		premises.map(\.formula) + [conclusion?.formula].compactMap(\.self)
	}

	func renamed(_ mapping: [Int: Int]) -> LogicArgument {
		LogicArgument(
			premises: premises.map { LogicStatement(formula: $0.formula.renamed(mapping), range: $0.range) },
			conclusion: conclusion.map { LogicStatement(formula: $0.formula.renamed(mapping), range: $0.range) }
		)
	}
}

private extension LogicFormula {
	/// Only atoms, since only propositional formulas get compared
	var slots: Set<Int> {
		switch self {
			case let .atom(slot):
				[slot]
			case let .not(value):
				value.slots
			case let .and(left, right), let .or(left, right), let .xor(left, right),
			     let .implies(left, right), let .iff(left, right):
				left.slots.union(right.slots)
			case .truth, .necessarily, .possibly, .forAll, .exists, .predicate, .relation:
				[]
		}
	}

	func renamed(_ mapping: [Int: Int]) -> LogicFormula {
		switch self {
			case let .atom(slot):
				.atom(mapping[slot] ?? slot)
			case let .not(value):
				.not(value.renamed(mapping))
			case let .and(left, right):
				.and(left.renamed(mapping), right.renamed(mapping))
			case let .or(left, right):
				.or(left.renamed(mapping), right.renamed(mapping))
			case let .xor(left, right):
				.xor(left.renamed(mapping), right.renamed(mapping))
			case let .implies(left, right):
				.implies(left.renamed(mapping), right.renamed(mapping))
			case let .iff(left, right):
				.iff(left.renamed(mapping), right.renamed(mapping))
			case .truth, .necessarily, .possibly, .forAll, .exists, .predicate, .relation:
				self
		}
	}
}
