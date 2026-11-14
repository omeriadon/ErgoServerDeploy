//
//  LogicFormula.swift
//  Ergo
//
//  Created by Adon Omeri on 4/11/2026.
//

import Foundation

/// Letters are kept as slots (1...6) all the way through, the same as the editor
public indirect enum LogicFormula: Hashable, Sendable {
	case atom(Int)
	case truth

	case not(LogicFormula)
	case and(LogicFormula, LogicFormula)
	case or(LogicFormula, LogicFormula)
	case xor(LogicFormula, LogicFormula)
	case implies(LogicFormula, LogicFormula)
	case iff(LogicFormula, LogicFormula)

	case necessarily(LogicFormula)
	case possibly(LogicFormula)

	case forAll(Int, LogicFormula)
	case exists(Int, LogicFormula)

	case predicate(Int, [LogicTerm])
	case relation(LogicRelation, LogicTerm, LogicTerm)

	/// True when a truth table alone can settle it, no modal, quantifier, identity, or set notation
	public var isPropositional: Bool {
		switch self {
			case .atom, .truth:
				true
			case let .not(value):
				value.isPropositional
			case let .and(left, right), let .or(left, right), let .xor(left, right),
			     let .implies(left, right), let .iff(left, right):
				left.isPropositional && right.isPropositional
			case .necessarily, .possibly, .forAll, .exists, .predicate, .relation:
				false
		}
	}

	public func text(letters: [String]) -> String {
		LogicFormulaPrinter(letters: letters).text(for: self)
	}
}

public indirect enum LogicTerm: Hashable, Sendable {
	case variable(Int)
	case emptySet
	case union(LogicTerm, LogicTerm)
	case intersection(LogicTerm, LogicTerm)
}

public enum LogicRelation: Hashable, Sendable {
	case equal
	case notEqual
	case member
	case notMember
	case properSubset
	case subset

	public var glyph: String {
		switch self {
			case .equal: "="
			case .notEqual: "≠"
			case .member: "∈"
			case .notMember: "∉"
			case .properSubset: "⊂"
			case .subset: "⊆"
		}
	}

	public init?(_ entry: LogicKeyboardEntry) {
		switch entry {
			case .symbol("="): self = .equal
			case .symbol("≠"): self = .notEqual
			case .symbol("∈"): self = .member
			case .symbol("∉"): self = .notMember
			case .symbol("⊂"): self = .properSubset
			case .symbol("⊆"): self = .subset
			default: return nil
		}
	}
}

/// Prints with the fewest brackets that still parse back to the same formula
private struct LogicFormulaPrinter {
	let letters: [String]

	func text(for formula: LogicFormula) -> String {
		switch formula {
			case let .atom(slot):
				LogicLetters.letter(for: slot, in: letters)
			case .truth:
				"⊤"
			case let .not(value):
				"¬" + unary(value)
			case let .necessarily(value):
				"□" + unary(value)
			case let .possibly(value):
				"◇" + unary(value)
			case let .forAll(slot, value):
				"∀" + LogicLetters.letter(for: slot, in: letters) + " " + unary(value)
			case let .exists(slot, value):
				"∃" + LogicLetters.letter(for: slot, in: letters) + " " + unary(value)
			case let .and(left, right):
				binary(left, "∧", right, of: formula)
			case let .or(left, right):
				binary(left, "∨", right, of: formula)
			case let .xor(left, right):
				binary(left, "⊕", right, of: formula)
			case let .implies(left, right):
				binary(left, "→", right, of: formula)
			case let .iff(left, right):
				binary(left, "↔", right, of: formula)
			case let .predicate(slot, terms):
				LogicLetters.letter(for: slot, in: letters) + "(" + terms.map(text).joined(separator: ", ") + ")"
			case let .relation(relation, left, right):
				text(for: left) + " " + relation.glyph + " " + text(for: right)
		}
	}

	private func text(for term: LogicTerm) -> String {
		switch term {
			case let .variable(slot):
				LogicLetters.letter(for: slot, in: letters)
			case .emptySet:
				"∅"
			case let .union(left, right):
				text(for: left) + " ∪ " + text(for: right)
			case let .intersection(left, right):
				text(for: left) + " ∩ " + text(for: right)
		}
	}

	private func unary(_ formula: LogicFormula) -> String {
		precedence(of: formula) < 5 ? "(" + text(for: formula) + ")" : text(for: formula)
	}

	/// Left-associative except →, which groups to the right
	private func binary(_ left: LogicFormula, _ glyph: String, _ right: LogicFormula, of formula: LogicFormula) -> String {
		let level = precedence(of: formula)
		let rightAssociative = if case .implies = formula {
			true
		} else {
			false
		}

		let leftNeedsBrackets = rightAssociative ? precedence(of: left) <= level : precedence(of: left) < level
		let rightNeedsBrackets = rightAssociative ? precedence(of: right) < level : precedence(of: right) <= level

		let leftText = leftNeedsBrackets ? "(" + text(for: left) + ")" : text(for: left)
		let rightText = rightNeedsBrackets ? "(" + text(for: right) + ")" : text(for: right)
		return leftText + " " + glyph + " " + rightText
	}

	private func precedence(of formula: LogicFormula) -> Int {
		switch formula {
			case .iff: 1
			case .implies: 2
			case .or, .xor: 3
			case .and: 4
			case .not, .necessarily, .possibly, .forAll, .exists: 5
			case .atom, .truth, .predicate, .relation: 6
		}
	}
}
