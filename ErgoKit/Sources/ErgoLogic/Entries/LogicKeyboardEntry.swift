//
//  LogicKeyboardEntry.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import Foundation

/// What the editor holds, one per glyph. Saved on boards as synthesized Codable, so never rename a case.
public enum LogicKeyboardEntry: Hashable, Sendable, Codable {
	/// One of the six configurable letters, stored by slot (1...6) so the letter itself can change without touching what's been written
	case variable(Int)
	case symbol(String)
	case delimiter(String)

	public func glyph(letters: [String]) -> String {
		switch self {
			case let .variable(slot):
				LogicLetters.letter(for: slot, in: letters)
			case let .symbol(value), let .delimiter(value):
				value
		}
	}

	public var id: String {
		switch self {
			case let .variable(slot):
				"variable.\(slot)"
			case let .symbol(value):
				"symbol.\(value)"
			case let .delimiter(value):
				"delimiter.\(value)"
		}
	}

	public var isVariable: Bool {
		if case .variable = self {
			return true
		}
		return false
	}

	public var alternate: LogicKeyboardEntry? {
		switch self {
			case .symbol("="): .symbol("≠")
			case .symbol("∈"): .symbol("∉")
			case .symbol("⊂"): .symbol("⊆")
			default: nil
		}
	}

	public static let variables: [LogicKeyboardEntry] = LogicLetters.slots.map { .variable($0) }

	public static let topRows: [[LogicKeyboardEntry]] = [
		[.symbol("="), .symbol("∈"), .symbol("∪"), .symbol("∩"), .symbol("⊂"), .symbol("∅")],
		[.symbol("∴"), .symbol("∵"), .symbol("≔"), .symbol("∎")],
	]

	public static let bottomRows: [[LogicKeyboardEntry]] = [
		[.symbol("↔"), .symbol("⊕"), .symbol("⊤"), .symbol("∀"), .symbol("∃")],
		[.symbol("□"), .symbol("◇"), .symbol("⊢"), .symbol("⊨"), .symbol("⇔")],
	]

	public static let structuralRow: [LogicKeyboardEntry] = [
		.symbol("¬"), .symbol("∧"), .symbol("∨"), .symbol("→"),
		.delimiter("("), .delimiter(")"), .delimiter("["), .delimiter("]"),
	]

	public static let fixedEntries: [LogicKeyboardEntry] = structuralRow + [
		.delimiter(","), .delimiter("\n"),
	]

	/// Every non-letter entry the keyboard can produce, alternates included
	public static let symbolEntries: [LogicKeyboardEntry] = {
		let base = fixedEntries + topRows.flatMap(\.self) + bottomRows.flatMap(\.self)
		return base + base.compactMap(\.alternate)
	}()
}
