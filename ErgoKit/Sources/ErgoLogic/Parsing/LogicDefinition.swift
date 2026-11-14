//
//  LogicDefinition.swift
//  ErgoKit
//
//  Created by Adon Omeri on 7/11/2026.
//

import Foundation

/// `X≔Y∧Z`: X is a name for Y∧Z. It isn't a claim, so it's neither true nor false, and checking
/// replaces the letter with what it stands for.
public struct LogicDefinition: Equatable, Sendable {
	public enum Value: Equatable, Sendable {
		case formula(LogicFormula)

		/// A set on its own, like `X∪Y`
		case term(LogicTerm)

		var letters: Set<Int> {
			switch self {
				case let .formula(formula):
					formula.letters
				case let .term(term):
					term.letters
			}
		}
	}

	/// Above any letter a person can write, for a quantifier that had to give up its own
	static let firstRenamed = 1000

	/// The letter's slot
	public let name: Int
	public let value: Value

	/// Entry indices in the editor
	public let range: Range<Int>

	public init(name: Int, value: Value, range: Range<Int>) {
		self.name = name
		self.value = value
		self.range = range
	}
}

public extension LogicParse {
	/// The argument with every defined letter replaced by what it stands for, which is what gets checked
	var expandedArgument: LogicArgument {
		let values = Dictionary(definitions.map { ($0.name, $0.value) }) { first, _ in first }
		guard !values.isEmpty else { return argument }

		func expanded(_ statement: LogicStatement) -> LogicStatement {
			LogicStatement(formula: statement.formula.expanding(values), range: statement.range)
		}
		return LogicArgument(premises: argument.premises.map(expanded), conclusion: argument.conclusion.map(expanded))
	}
}

extension LogicParse {
	/// The first definition or statement that's over `LogicParser.maximumWrittenOutLength` once its letters are written
	/// out. Counted without writing anything out, since that's what there'd be no room for. Only call when no
	/// definition is circular.
	var firstOversized: LogicDiagnostic? {
		guard !definitions.isEmpty else { return nil }

		let limit = LogicParser.maximumWrittenOutLength
		let values = Dictionary(definitions.map { ($0.name, $0.value) }) { first, _ in first }
		var sizes: [Int: Int] = [:]

		// Never more than a little past the limit, so nothing overflows however much the letters multiply
		func size(of letter: Int) -> Int {
			if let known = sizes[letter] {
				return known
			}
			let size: Int = switch values[letter] {
				case let .formula(formula): formula.size(size(of:), limit: limit)
				case let .term(term): term.size(size(of:), limit: limit)
				case nil: 1
			}
			sizes[letter] = size
			return size
		}

		if let definition = definitions.first(where: { size(of: $0.name) > limit }) {
			return LogicDiagnostic(problem: .tooLongWrittenOut(limit: limit), range: definition.range)
		}
		let statements = (argument.premises + [argument.conclusion].compactMap(\.self)).sorted { $0.range.lowerBound < $1.range.lowerBound }
		if let statement = statements.first(where: { $0.formula.size(size(of:), limit: limit) > limit }) {
			return LogicDiagnostic(problem: .tooLongWrittenOut(limit: limit), range: statement.range)
		}
		return nil
	}
}

private extension LogicFormula {
	/// How many symbols it is with each letter counted as `letter` says, stopping just past `limit`
	func size(_ letter: (Int) -> Int, limit: Int) -> Int {
		let size: Int = switch self {
			case let .atom(slot):
				letter(slot)
			case .truth:
				1
			case let .not(value), let .necessarily(value), let .possibly(value):
				1 + value.size(letter, limit: limit)
			case let .and(left, right), let .or(left, right), let .xor(left, right),
			     let .implies(left, right), let .iff(left, right):
				1 + left.size(letter, limit: limit) + right.size(letter, limit: limit)
			case let .forAll(_, body), let .exists(_, body):
				1 + body.size(letter, limit: limit)
			case let .predicate(_, terms):
				terms.reduce(1) { min($0 + $1.size(letter, limit: limit), limit + 1) }
			case let .relation(_, left, right):
				1 + left.size(letter, limit: limit) + right.size(letter, limit: limit)
		}
		return min(size, limit + 1)
	}
}

private extension LogicTerm {
	func size(_ letter: (Int) -> Int, limit: Int) -> Int {
		let size: Int = switch self {
			case let .variable(slot):
				letter(slot)
			case .emptySet:
				1
			case let .union(left, right), let .intersection(left, right):
				1 + left.size(letter, limit: limit) + right.size(letter, limit: limit)
		}
		return min(size, limit + 1)
	}
}

extension [LogicDefinition] {
	/// The first definition that ends up depending on its own letter
	var firstCircular: LogicDefinition? {
		let values = Dictionary(map { ($0.name, $0.value) }) { first, _ in first }

		func reaches(_ target: Int, from slot: Int, visited: inout Set<Int>) -> Bool {
			guard let value = values[slot] else { return false }
			for letter in value.letters {
				if letter == target {
					return true
				}
				if visited.insert(letter).inserted, reaches(target, from: letter, visited: &visited) {
					return true
				}
			}
			return false
		}

		return first { definition in
			var visited: Set<Int> = []
			return reaches(definition.name, from: definition.name, visited: &visited)
		}
	}
}

private extension LogicFormula {
	/// Every letter it uses that no ∀ or ∃ binds. A predicate's own name isn't one of them.
	var letters: Set<Int> {
		switch self {
			case let .atom(slot):
				[slot]
			case .truth:
				[]
			case let .not(value), let .necessarily(value), let .possibly(value):
				value.letters
			case let .and(left, right), let .or(left, right), let .xor(left, right),
			     let .implies(left, right), let .iff(left, right):
				left.letters.union(right.letters)
			case let .forAll(slot, body), let .exists(slot, body):
				body.letters.subtracting([slot])
			case let .predicate(_, terms):
				terms.reduce(into: []) { $0.formUnion($1.letters) }
			case let .relation(_, left, right):
				left.letters.union(right.letters)
		}
	}

	/// `values` can't be circular, the parser refuses those. `bound` is the letters ∀ and ∃ own here: they aren't the
	/// defined letter in a comparison, but a statement letter is still the defined one, since those are unrelated.
	func expanding(_ values: [Int: LogicDefinition.Value], bound: Set<Int> = []) -> LogicFormula {
		switch self {
			case let .atom(slot):
				if case let .formula(value) = values[slot] {
					value.expanding(values)
				} else {
					self
				}
			case .truth:
				self
			case let .not(value):
				.not(value.expanding(values, bound: bound))
			case let .necessarily(value):
				.necessarily(value.expanding(values, bound: bound))
			case let .possibly(value):
				.possibly(value.expanding(values, bound: bound))
			case let .and(left, right):
				.and(left.expanding(values, bound: bound), right.expanding(values, bound: bound))
			case let .or(left, right):
				.or(left.expanding(values, bound: bound), right.expanding(values, bound: bound))
			case let .xor(left, right):
				.xor(left.expanding(values, bound: bound), right.expanding(values, bound: bound))
			case let .implies(left, right):
				.implies(left.expanding(values, bound: bound), right.expanding(values, bound: bound))
			case let .iff(left, right):
				.iff(left.expanding(values, bound: bound), right.expanding(values, bound: bound))
			case let .forAll(slot, body):
				expandingBinder(slot, body, values, bound: bound, LogicFormula.forAll)
			case let .exists(slot, body):
				expandingBinder(slot, body, values, bound: bound, LogicFormula.exists)
			case let .predicate(slot, terms):
				.predicate(slot, terms.map { $0.expanding(values, bound: bound) })
			case let .relation(relation, left, right):
				.relation(relation, left.expanding(values, bound: bound), right.expanding(values, bound: bound))
		}
	}

	/// A definition that mentions the quantifier's letter means the one outside it, so the quantifier takes a new
	/// letter rather than capturing it
	private func expandingBinder(
		_ slot: Int,
		_ body: LogicFormula,
		_ values: [Int: LogicDefinition.Value],
		bound: Set<Int>,
		_ make: (Int, LogicFormula) -> LogicFormula
	) -> LogicFormula {
		let isCaptured = values.values.contains { $0.letters.contains(slot) }
		guard isCaptured else {
			return make(slot, body.expanding(values, bound: bound.union([slot])))
		}

		let new = (bound.union(body.allLetters).max() ?? 0) + LogicDefinition.firstRenamed
		return make(new, body.renamingBound(slot, to: new).expanding(values, bound: bound.union([new])))
	}

	var allLetters: Set<Int> {
		switch self {
			case let .atom(slot):
				[slot]
			case .truth:
				[]
			case let .not(value), let .necessarily(value), let .possibly(value):
				value.allLetters
			case let .and(left, right), let .or(left, right), let .xor(left, right),
			     let .implies(left, right), let .iff(left, right):
				left.allLetters.union(right.allLetters)
			case let .forAll(slot, body), let .exists(slot, body):
				body.allLetters.union([slot])
			case let .predicate(slot, terms):
				terms.reduce(into: [slot]) { $0.formUnion($1.letters) }
			case let .relation(_, left, right):
				left.letters.union(right.letters)
		}
	}

	/// Only in comparisons and predicates, since a statement letter isn't what ∀ and ∃ bind
	func renamingBound(_ slot: Int, to new: Int) -> LogicFormula {
		switch self {
			case .atom, .truth:
				self
			case let .not(value):
				.not(value.renamingBound(slot, to: new))
			case let .necessarily(value):
				.necessarily(value.renamingBound(slot, to: new))
			case let .possibly(value):
				.possibly(value.renamingBound(slot, to: new))
			case let .and(left, right):
				.and(left.renamingBound(slot, to: new), right.renamingBound(slot, to: new))
			case let .or(left, right):
				.or(left.renamingBound(slot, to: new), right.renamingBound(slot, to: new))
			case let .xor(left, right):
				.xor(left.renamingBound(slot, to: new), right.renamingBound(slot, to: new))
			case let .implies(left, right):
				.implies(left.renamingBound(slot, to: new), right.renamingBound(slot, to: new))
			case let .iff(left, right):
				.iff(left.renamingBound(slot, to: new), right.renamingBound(slot, to: new))
			case let .forAll(other, body):
				other == slot ? self : .forAll(other, body.renamingBound(slot, to: new))
			case let .exists(other, body):
				other == slot ? self : .exists(other, body.renamingBound(slot, to: new))
			case let .predicate(name, terms):
				.predicate(name, terms.map { $0.renaming([slot: new]) })
			case let .relation(relation, left, right):
				.relation(relation, left.renaming([slot: new]), right.renaming([slot: new]))
		}
	}
}

private extension LogicTerm {
	var letters: Set<Int> {
		switch self {
			case let .variable(slot):
				[slot]
			case .emptySet:
				[]
			case let .union(left, right), let .intersection(left, right):
				left.letters.union(right.letters)
		}
	}

	func expanding(_ values: [Int: LogicDefinition.Value], bound: Set<Int>) -> LogicTerm {
		switch self {
			case let .variable(slot):
				guard !bound.contains(slot) else { return self }
				switch values[slot] {
					case let .term(value):
						return value.expanding(values, bound: bound)
					// X≔Y parses as a statement, but it's just as good a name for a set
					case let .formula(.atom(other)):
						return LogicTerm.variable(other).expanding(values, bound: bound)
					default:
						return self
				}
			case .emptySet:
				return self
			case let .union(left, right):
				return .union(left.expanding(values, bound: bound), right.expanding(values, bound: bound))
			case let .intersection(left, right):
				return .intersection(left.expanding(values, bound: bound), right.expanding(values, bound: bound))
		}
	}
}
