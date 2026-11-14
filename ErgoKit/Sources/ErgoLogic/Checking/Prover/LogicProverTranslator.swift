//
//  LogicProverTranslator.swift
//  Ergo
//
//  Created by Adon Omeri on 8/11/2026.
//

import Foundation

struct Measure {
	var isMonadic = true
	var quantifiers = 0
	var predicates: Set<Fact.Kind> = []
	var names: Set<Int> = []

	mutating func add(_ node: Node) {
		switch node {
			case .top, .bottom:
				break
			case let .fact(fact, _):
				if case .statement = fact.kind {
					return
				}
				predicates.insert(fact.kind)
				if fact.things.count > 1 {
					isMonadic = false
				}
				fact.things.forEach { add($0) }
			case let .same(left, right, _):
				add(left)
				add(right)
			case let .and(left, right), let .or(left, right):
				add(left)
				add(right)
			case let .always(value), let .sometimes(value):
				isMonadic = false
				add(value)
			case let .all(_, body), let .some(_, body):
				quantifiers += 1
				add(body)
		}
	}

	private mutating func add(_ thing: Thing) {
		if case let .name(name) = thing {
			names.insert(name)
		}
	}
}

// MARK: - Translating

struct Translator {
	/// A ∀ or ∃ over sets, which is second order
	struct Unsupported: Error {}

	let sorts: LogicSorts
	let firstBound: Int
	var nextMadeUp: Int

	mutating func translate(_ formula: LogicFormula, positive: Bool) throws -> Node {
		switch formula {
			case let .atom(slot):
				return .fact(Fact(kind: .statement(slot), things: []), positive)
			case .truth:
				return positive ? .top : .bottom
			case let .not(value):
				return try translate(value, positive: !positive)
			case let .and(left, right):
				let (left, right) = try (translate(left, positive: positive), translate(right, positive: positive))
				return positive ? both(left, right) : either(left, right)
			case let .or(left, right):
				let (left, right) = try (translate(left, positive: positive), translate(right, positive: positive))
				return positive ? either(left, right) : both(left, right)
			case let .implies(left, right):
				let (left, right) = try (translate(left, positive: !positive), translate(right, positive: positive))
				return positive ? either(left, right) : both(left, right)
			case let .iff(left, right):
				return try equivalent(left, right, positive: positive)
			case let .xor(left, right):
				return try equivalent(left, right, positive: !positive)
			case let .necessarily(value):
				let value = try translate(value, positive: positive)
				return positive ? .always(value) : .sometimes(value)
			case let .possibly(value):
				let value = try translate(value, positive: positive)
				return positive ? .sometimes(value) : .always(value)
			case let .forAll(letter, body):
				guard !sorts.isSet(letter) else { throw Unsupported() }
				let body = try translate(body, positive: positive)
				return positive ? .all(letter, body) : .some(letter, body)
			case let .exists(letter, body):
				guard !sorts.isSet(letter) else { throw Unsupported() }
				let body = try translate(body, positive: positive)
				return positive ? .some(letter, body) : .all(letter, body)
			case let .predicate(slot, terms):
				return try .fact(Fact(kind: .predicate(slot), things: terms.map(thing)), positive)
			case let .relation(relation, left, right):
				let node = try translate(relation, left, right)
				return positive ? node : node.negated
		}
	}

	private mutating func equivalent(_ left: LogicFormula, _ right: LogicFormula, positive: Bool) throws -> Node {
		let (leftTrue, rightTrue) = try (translate(left, positive: true), translate(right, positive: true))
		let (leftFalse, rightFalse) = (leftTrue.negated, rightTrue.negated)
		return positive
			? either(both(leftTrue, rightTrue), both(leftFalse, rightFalse))
			: either(both(leftTrue, rightFalse), both(leftFalse, rightTrue))
	}

	private mutating func translate(_ relation: LogicRelation, _ left: LogicTerm, _ right: LogicTerm) throws -> Node {
		switch relation {
			case .equal:
				return try equal(left, right)
			case .notEqual:
				return try equal(left, right).negated
			case .member:
				return try contains(right, thing(left))
			case .notMember:
				return try contains(right, thing(left)).negated
			case .subset:
				return try subset(left, right)
			case .properSubset:
				let witness = madeUpLetter()
				let member = Thing.bound(witness)
				return try both(subset(left, right), .some(witness, both(contains(right, member), contains(left, member).negated)))
		}
	}

	/// Sets are equal when they have the same things in them
	private mutating func equal(_ left: LogicTerm, _ right: LogicTerm) throws -> Node {
		if case let .variable(first) = left, case let .variable(second) = right, !sorts.isSet(first), !sorts.isSet(second) {
			return try .same(thing(left), thing(right), true)
		}

		let letter = madeUpLetter()
		let member = Thing.bound(letter)
		let (inLeft, inRight) = try (contains(left, member), contains(right, member))
		return .all(letter, either(both(inLeft, inRight), both(inLeft.negated, inRight.negated)))
	}

	private mutating func subset(_ left: LogicTerm, _ right: LogicTerm) throws -> Node {
		let letter = madeUpLetter()
		let member = Thing.bound(letter)
		return try .all(letter, either(contains(left, member).negated, contains(right, member)))
	}

	func contains(_ set: LogicTerm, _ member: Thing) throws -> Node {
		switch set {
			case let .variable(slot):
				guard slot < firstBound else { throw Unsupported() }
				return .fact(Fact(kind: .set(slot), things: [member]), true)
			case .emptySet:
				return .bottom
			case let .union(left, right):
				return try either(contains(left, member), contains(right, member))
			case let .intersection(left, right):
				return try both(contains(left, member), contains(right, member))
		}
	}

	func thing(_ term: LogicTerm) throws -> Thing {
		guard case let .variable(slot) = term else { throw Unsupported() }
		return slot < firstBound ? .name(slot) : .bound(slot)
	}

	private mutating func madeUpLetter() -> Int {
		nextMadeUp += 1
		return nextMadeUp
	}
}
