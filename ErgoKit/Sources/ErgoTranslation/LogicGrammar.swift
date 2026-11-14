//
//  LogicGrammar.swift
//  Ergo
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoLogic
import Foundation

/// What a model needs to know to write logic `LogicParser` accepts.
/// Sent with each request instead of living in a prompt, so it always matches this build's parser.
public enum LogicGrammar {
	/// Bump whenever the parser accepts something different
	public static let version = 1

	private static let symbols: [(glyph: String, meaning: String)] = [
		("¬", "not, prefix: ¬A"),
		("∧", "and: A∧B"),
		("∨", "inclusive or: A∨B"),
		("⊕", "exclusive or, exactly one: A⊕B"),
		("→", "if…then, groups to the right: A→B→C is A→(B→C)"),
		("↔", "if and only if: A↔B (⇔ means the same)"),
		("⊤", "always true"),
		("( ) [ ]", "grouping, must match"),
		("□", "necessarily, prefix: □A"),
		("◇", "possibly, prefix: ◇A"),
		("∀", "for every, followed by one letter: ∀X P(X)"),
		("∃", "for some, followed by one letter: ∃X P(X)"),
		("P(X, Y)", "predicate: a letter directly followed by letters in brackets"),
		("= ≠", "letters or sets are equal / not equal: X=Y"),
		("∈ ∉", "is / isn't a member of: X∈Y"),
		("⊂ ⊆", "proper subset / subset: X⊂Y"),
		("∪ ∩ ∅", "set union, intersection, the empty set; only inside = ≠ ∈ ∉ ⊂ ⊆"),
	]

	/// Plain text, with the user's letters filled in
	public static func reference(letters: [String]) -> String {
		let letters = LogicLetters.resolved(letters)

		return """
		Letters: \(letters.joined(separator: " ")). Each stands for one simple claim. No other letters exist.
		Symbols:
		\(symbols.map { "\($0.glyph)  \($0.meaning)" }.joined(separator: "\n"))
		Binding, tightest first: ¬ □ ◇ ∀ ∃, then ∧, then ∨ ⊕, then →, then ↔.
		Write each statement on its own, without ∴. Commas only go between a predicate's letters. Spaces are ignored.
		Use brackets whenever grouping isn't obvious.
		"""
	}
}
