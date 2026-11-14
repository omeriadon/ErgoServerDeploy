//
//  FormulaParser.swift
//  Ergo
//
//  Created by Adon Omeri on 8/11/2026.
//

import Foundation

/// Recursive descent over one statement
struct FormulaParser {
	let entries: [LogicKeyboardEntry]
	let range: Range<Int>
	var index: Int

	/// How many brackets and ¬ □ ◇ ∀ ∃ the statement being read is inside
	private var depth = 0

	init(entries: [LogicKeyboardEntry], range: Range<Int>) {
		self.entries = entries
		self.range = range
		index = range.lowerBound
	}

	var current: LogicKeyboardEntry? {
		index < range.upperBound ? entries[index] : nil
	}

	var next: LogicKeyboardEntry? {
		index + 1 < range.upperBound ? entries[index + 1] : nil
	}

	var previous: LogicKeyboardEntry? {
		index > range.lowerBound ? entries[index - 1] : nil
	}

	func failure(_ problem: LogicProblem, at position: Int? = nil) -> LogicDiagnostic {
		let position = min(position ?? index, max(range.upperBound - 1, range.lowerBound))
		return LogicDiagnostic(problem: problem, range: position ..< position + 1)
	}

	mutating func parseStatement() throws -> LogicFormula {
		let formula = try biconditional()

		if let current {
			switch current {
				case .delimiter(")"), .delimiter("]"):
					throw failure(.unexpected(current))
				case .variable, .symbol("⊤"), .symbol("∅"), .delimiter("("), .delimiter("["),
				     .symbol("¬"), .symbol("□"), .symbol("◇"), .symbol("∀"), .symbol("∃"):
					throw failure(.missingConnective(before: current))
				default:
					throw failure(.unexpected(current))
			}
		}

		return formula
	}

	/// After ≔, where a set is fine on its own
	mutating func parseDefinitionValue() throws -> LogicDefinition.Value {
		var formula = self
		do {
			return try .formula(formula.parseStatement())
		} catch let diagnostic as LogicDiagnostic {
			guard case .setWithoutRelation = diagnostic.problem else { throw diagnostic }
			let set = term()
			guard current == nil else { throw diagnostic }
			return .term(set)
		}
	}

	private mutating func biconditional() throws -> LogicFormula {
		var left = try implication()
		while current == .symbol("↔") || current == .symbol("⇔") {
			index += 1
			left = try .iff(left, implication())
		}
		return left
	}

	private mutating func implication() throws -> LogicFormula {
		let left = try disjunction()
		guard current == .symbol("→") else { return left }
		index += 1
		return try .implies(left, implication())
	}

	private mutating func disjunction() throws -> LogicFormula {
		var left = try conjunction()
		while let current, current == .symbol("∨") || current == .symbol("⊕") {
			index += 1
			let right = try conjunction()
			left = current == .symbol("∨") ? .or(left, right) : .xor(left, right)
		}
		return left
	}

	private mutating func conjunction() throws -> LogicFormula {
		var left = try unary()
		while current == .symbol("∧") {
			index += 1
			left = try .and(left, unary())
		}
		return left
	}

	private mutating func unary() throws -> LogicFormula {
		// Everything that reads a formula goes as deep as it does, so one nested without end would run out of stack
		depth += 1
		defer { depth -= 1 }
		guard depth <= LogicParser.maximumDepth else {
			throw failure(.tooDeep(limit: LogicParser.maximumDepth))
		}

		switch current {
			case .symbol("¬"):
				index += 1
				return try .not(unary())

			case .symbol("□"):
				index += 1
				return try .necessarily(unary())

			case .symbol("◇"):
				index += 1
				return try .possibly(unary())

			case let .some(quantifier) where quantifier == .symbol("∀") || quantifier == .symbol("∃"):
				index += 1
				guard case let .variable(slot) = current else {
					throw failure(.expectedLetter(after: quantifier), at: index - 1)
				}
				index += 1
				let body = try unary()
				return quantifier == .symbol("∀") ? .forAll(slot, body) : .exists(slot, body)

			default:
				return try primary()
		}
	}

	private mutating func primary() throws -> LogicFormula {
		guard let current else {
			throw failure(.expectedFormula(after: previous), at: index - 1)
		}

		switch current {
			case .symbol("⊤"):
				index += 1
				return .truth

			case .delimiter("("), .delimiter("["):
				let open = index
				index += 1
				let inner = try biconditional()
				let expected: LogicKeyboardEntry = current == .delimiter("(") ? .delimiter(")") : .delimiter("]")

				guard let close = self.current else {
					throw failure(.unclosed(current), at: open)
				}
				guard close == expected else {
					if close == .delimiter(")") || close == .delimiter("]") {
						throw failure(.mismatched(open: current, close: close))
					}
					if close == .delimiter(",") {
						throw failure(.unexpected(close))
					}
					throw failure(.missingConnective(before: close))
				}

				index += 1
				return inner

			case let .variable(slot) where next == .delimiter("("):
				index += 2
				return try .predicate(slot, arguments(open: index - 1))

			case .variable, .symbol("∅"):
				let start = index
				let left = term()

				if let relationEntry = self.current, let relation = LogicRelation(relationEntry) {
					index += 1
					guard let right = termIfPresent() else {
						if let unexpected = self.current {
							throw failure(.unexpected(unexpected))
						}
						throw failure(.expectedFormula(after: relationEntry), at: index - 1)
					}
					return .relation(relation, left, right)
				}

				if case let .variable(slot) = left {
					return .atom(slot)
				}
				let set = entries[start ..< index].first { $0 == .symbol("∪") || $0 == .symbol("∩") } ?? .symbol("∅")
				throw LogicDiagnostic(problem: .setWithoutRelation(set), range: start ..< index)

			case .symbol("∧"), .symbol("∨"), .symbol("⊕"), .symbol("→"), .symbol("↔"), .symbol("⇔"):
				if previous == nil {
					throw failure(.unexpected(current))
				}
				throw failure(.expectedFormula(after: previous), at: index - 1)

			case .delimiter(")"), .delimiter("]"):
				if previous == nil {
					throw failure(.unexpected(current))
				}
				throw failure(.expectedFormula(after: previous), at: index - 1)

			case .symbol("≠"), .symbol("="), .symbol("∈"), .symbol("∉"), .symbol("⊂"), .symbol("⊆"), .symbol("∪"), .symbol("∩"):
				throw failure(.unexpected(current))

			default:
				throw failure(.unexpected(current))
		}
	}

	/// After `P(`, reads `X, Y)`
	private mutating func arguments(open: Int) throws -> [LogicTerm] {
		var terms: [LogicTerm] = []

		while true {
			guard let term = termIfPresent() else {
				guard let current else {
					throw failure(.unclosed(.delimiter("(")), at: open)
				}
				// P() or P(X,)
				if current == .delimiter(")"), let previous {
					throw failure(.expectedLetter(after: previous), at: index - 1)
				}
				throw failure(.unexpected(current))
			}
			terms.append(term)

			switch current {
				case .delimiter(","):
					index += 1
				case .delimiter(")"):
					index += 1
					return terms
				case nil:
					throw failure(.unclosed(.delimiter("(")), at: open)
				case let .some(entry):
					throw failure(.unexpected(entry))
			}
		}
	}

	private mutating func termIfPresent() -> LogicTerm? {
		switch current {
			case .variable, .symbol("∅"):
				term()
			default:
				nil
		}
	}

	/// Letters and ∅, joined left to right by ∪ and ∩. Only call when the current entry starts a term.
	private mutating func term() -> LogicTerm {
		var left = termPrimary()

		while let current, current == .symbol("∪") || current == .symbol("∩") {
			guard let right = peekTermPrimary(at: index + 1) else { break }
			index += 2
			left = current == .symbol("∪") ? .union(left, right) : .intersection(left, right)
		}

		return left
	}

	private mutating func termPrimary() -> LogicTerm {
		let term = peekTermPrimary(at: index) ?? .emptySet
		index += 1
		return term
	}

	func peekTermPrimary(at position: Int) -> LogicTerm? {
		guard position < range.upperBound else { return nil }

		switch entries[position] {
			case let .variable(slot):
				return .variable(slot)
			case .symbol("∅"):
				return .emptySet
			default:
				return nil
		}
	}
}
