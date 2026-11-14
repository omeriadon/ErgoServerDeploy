//
//  LogicSorts.swift
//  ErgoKit
//
//  Created by Adon Omeri on 7/11/2026.
//

import Foundation

/// Which letters are members and which are sets, worked out from how they're used. A letter nothing pins down is a
/// member. Sets hold members, never other sets, so `X∈Y, Y∈Z` is a mistake and checking stays decidable.
///
/// A letter on its own as a statement is unrelated to the same letter in a comparison, and letters bound by ∀ or ∃
/// are only themselves within it, so formulas go through `uniquelyBound` first.
struct LogicSorts {
	enum Conflict: Equatable {
		case letter(Int)
		case setAsMember
	}

	private enum Sort {
		case member, set
	}

	private var parents: [Int: Int] = [:]
	private var sorts: [Int: Sort] = [:]

	/// The letter each bound one was written as, for reporting a conflict
	var written: [Int: Int] = [:]

	private(set) var conflict: Conflict?

	func isSet(_ letter: Int) -> Bool {
		sorts[root(of: letter)] == .set
	}

	mutating func add(_ formula: LogicFormula) {
		switch formula {
			case .atom, .truth:
				break
			case let .not(value), let .necessarily(value), let .possibly(value):
				add(value)
			case let .and(left, right), let .or(left, right), let .xor(left, right),
			     let .implies(left, right), let .iff(left, right):
				add(left)
				add(right)
			case let .forAll(_, body), let .exists(_, body):
				add(body)
			case let .predicate(_, terms):
				for term in terms {
					requireMember(term)
				}
			case let .relation(relation, left, right):
				switch relation {
					case .equal, .notEqual:
						if case let .variable(first) = left, case let .variable(second) = right {
							unify(first, second)
						} else {
							requireSet(left)
							requireSet(right)
						}
					case .member, .notMember:
						requireMember(left)
						requireSet(right)
					case .properSubset, .subset:
						requireSet(left)
						requireSet(right)
				}
		}
	}

	private func root(of letter: Int) -> Int {
		var current = letter
		while let parent = parents[current] {
			current = parent
		}
		return current
	}

	private mutating func unify(_ first: Int, _ second: Int) {
		let (first, second) = (root(of: first), root(of: second))
		guard first != second else { return }

		if let sort = sorts[first], let other = sorts[second], sort != other {
			report(.letter(written[second] ?? second))
			return
		}
		parents[first] = second
		sorts[second] = sorts[second] ?? sorts[first]
	}

	private mutating func requireMember(_ term: LogicTerm) {
		guard case let .variable(letter) = term else {
			report(.setAsMember)
			return
		}
		require(letter, .member)
	}

	private mutating func requireSet(_ term: LogicTerm) {
		switch term {
			case let .variable(letter):
				require(letter, .set)
			case .emptySet:
				break
			case let .union(left, right), let .intersection(left, right):
				requireSet(left)
				requireSet(right)
		}
	}

	private mutating func require(_ letter: Int, _ sort: Sort) {
		let root = root(of: letter)
		if let known = sorts[root], known != sort {
			report(.letter(written[letter] ?? letter))
		} else {
			sorts[root] = sort
		}
	}

	private mutating func report(_ found: Conflict) {
		conflict = conflict ?? found
	}
}

extension LogicFormula {
	/// Every ∀ and ∃ gets a letter of its own, from `next` up, with `sorts` told what it was written as
	func uniquelyBound(_ scope: [Int: Int] = [:], next: inout Int, sorts: inout LogicSorts) -> LogicFormula {
		func recurse(_ formula: LogicFormula, next: inout Int, sorts: inout LogicSorts) -> LogicFormula {
			formula.uniquelyBound(scope, next: &next, sorts: &sorts)
		}

		switch self {
			case .atom, .truth:
				return self
			case let .not(value):
				return .not(recurse(value, next: &next, sorts: &sorts))
			case let .necessarily(value):
				return .necessarily(recurse(value, next: &next, sorts: &sorts))
			case let .possibly(value):
				return .possibly(recurse(value, next: &next, sorts: &sorts))
			case let .and(left, right):
				let left = recurse(left, next: &next, sorts: &sorts)
				return .and(left, recurse(right, next: &next, sorts: &sorts))
			case let .or(left, right):
				let left = recurse(left, next: &next, sorts: &sorts)
				return .or(left, recurse(right, next: &next, sorts: &sorts))
			case let .xor(left, right):
				let left = recurse(left, next: &next, sorts: &sorts)
				return .xor(left, recurse(right, next: &next, sorts: &sorts))
			case let .implies(left, right):
				let left = recurse(left, next: &next, sorts: &sorts)
				return .implies(left, recurse(right, next: &next, sorts: &sorts))
			case let .iff(left, right):
				let left = recurse(left, next: &next, sorts: &sorts)
				return .iff(left, recurse(right, next: &next, sorts: &sorts))
			case let .forAll(slot, body), let .exists(slot, body):
				let bound = next
				next += 1
				sorts.written[bound] = slot
				var inner = scope
				inner[slot] = bound
				let body = body.uniquelyBound(inner, next: &next, sorts: &sorts)
				if case .forAll = self {
					return .forAll(bound, body)
				}
				return .exists(bound, body)
			case let .predicate(slot, terms):
				return .predicate(slot, terms.map { $0.renaming(scope) })
			case let .relation(relation, left, right):
				return .relation(relation, left.renaming(scope), right.renaming(scope))
		}
	}
}

extension LogicTerm {
	func renaming(_ scope: [Int: Int]) -> LogicTerm {
		switch self {
			case let .variable(slot):
				.variable(scope[slot] ?? slot)
			case .emptySet:
				self
			case let .union(left, right):
				.union(left.renaming(scope), right.renaming(scope))
			case let .intersection(left, right):
				.intersection(left.renaming(scope), right.renaming(scope))
		}
	}
}
