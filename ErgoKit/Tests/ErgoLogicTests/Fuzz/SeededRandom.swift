//
//  SeededRandom.swift
//  ErgoKit
//
//  Created by Adon Omeri on 11/11/2026.
//

import ErgoLogic
import Foundation

/// SplitMix64, so a seed that fails can be run again and fails the same way
struct SeededRandom: RandomNumberGenerator {
	var state: UInt64

	init(seed: UInt64) {
		state = seed
	}

	mutating func next() -> UInt64 {
		state &+= 0x9E37_79B9_7F4A_7C15
		var z = state
		z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
		z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
		return z ^ (z >> 31)
	}
}

extension LogicFormula {
	/// A formula a truth table can settle, over the first `letters` letters, at most `depth` connectives deep
	static func random(depth: Int, letters: Int, using random: inout SeededRandom) -> LogicFormula {
		guard depth > 0, Int.random(in: 0 ..< 5, using: &random) > 0 else {
			return Int.random(in: 0 ..< 12, using: &random) == 0 ? .truth : .atom(Int.random(in: 1 ... letters, using: &random))
		}
		func part() -> LogicFormula {
			.random(depth: depth - 1, letters: letters, using: &random)
		}
		switch Int.random(in: 0 ..< 6, using: &random) {
			case 0: return .not(part())
			case 1: return .and(part(), part())
			case 2: return .or(part(), part())
			case 3: return .xor(part(), part())
			case 4: return .implies(part(), part())
			default: return .iff(part(), part())
		}
	}

	/// Worked out the slow, obvious way, to check the checker against. Only for what a truth table can settle.
	func isTrue(_ row: [Int: Bool]) -> Bool {
		switch self {
			case let .atom(slot):
				row[slot] ?? false
			case .truth:
				true
			case let .not(value):
				!value.isTrue(row)
			case let .and(left, right):
				left.isTrue(row) && right.isTrue(row)
			case let .or(left, right):
				left.isTrue(row) || right.isTrue(row)
			case let .xor(left, right):
				left.isTrue(row) != right.isTrue(row)
			case let .implies(left, right):
				!left.isTrue(row) || right.isTrue(row)
			case let .iff(left, right):
				left.isTrue(row) == right.isTrue(row)
			case .necessarily, .possibly, .forAll, .exists, .predicate, .relation:
				preconditionFailure("Expected a formula a truth table can settle")
		}
	}
}

/// Every way of setting the six letters true or false
let everyRow: [[Int: Bool]] = (0 ..< 64).map { bits in
	Dictionary(uniqueKeysWithValues: LogicLetters.slots.map { ($0, bits >> ($0 - 1) & 1 == 1) })
}
