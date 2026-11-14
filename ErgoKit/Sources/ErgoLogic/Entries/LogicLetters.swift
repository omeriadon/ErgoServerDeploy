//
//  LogicLetters.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import Foundation

public enum LogicLetters {
	public static let slots = 1 ... 6

	public static let defaults = ["X", "Y", "Z", "P", "Q", "R"]

	public enum Problem: Equatable, Sendable {
		case notALetter
		case alreadyUsed
	}

	public static func isAllowed(_ character: Character) -> Bool {
		character.isASCII && character.isLetter
	}

	/// Always six distinct letters, falling back to defaults for anything stored that isn't usable
	public static func resolved(_ stored: [String]) -> [String] {
		var letters: [String] = []

		for index in 0 ..< slots.count {
			var candidates = [defaults[index]] + "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map(String.init)
			if stored.indices.contains(index) {
				candidates.insert(stored[index], at: 0)
			}

			let letter = candidates.first { candidate in
				candidate.count == 1
					&& candidate.first.map(isAllowed) == true
					&& !letters.contains { $0.caseInsensitiveCompare(candidate) == .orderedSame }
			}
			letters.append(letter ?? defaults[index])
		}

		return letters
	}

	public static func letter(for slot: Int, in letters: [String]) -> String {
		let index = slot - slots.lowerBound
		return letters.indices.contains(index) ? letters[index] : defaults[index]
	}

	/// Checks whether `letter` can go in `slot`, ignoring whatever is in that slot right now
	public static func problem(with letter: String, in slot: Int, of letters: [String]) -> Problem? {
		guard letter.count == 1, let character = letter.first, isAllowed(character) else {
			return .notALetter
		}

		let others = letters.enumerated()
			.filter { $0.offset != slot - slots.lowerBound }
			.map(\.element)

		if others.contains(where: { $0.caseInsensitiveCompare(letter) == .orderedSame }) {
			return .alreadyUsed
		}

		return nil
	}

	// MARK: - Descriptors

	/// What each letter stands for on a board, short enough to label a key
	public static let descriptorWordLimit = 4
	public static let descriptorLengthLimit = 32

	public static let emptyDescriptors = Array(repeating: "", count: slots.count)

	/// Caps a descriptor while it's being typed, keeping a trailing space so the next word can start
	public static func limitedDescriptor(_ descriptor: String) -> String {
		var limited = ""
		var words = 0
		var previous: Character?

		for character in descriptor.prefix(descriptorLengthLimit) {
			if !character.isWhitespace, previous?.isWhitespace ?? true {
				words += 1
				guard words <= descriptorWordLimit else { break }
			}
			limited.append(character)
			previous = character
		}

		return limited
	}

	/// What's actually stored: trimmed, single spaced, at most four words and 32 characters
	public static func sanitizedDescriptor(_ descriptor: String) -> String {
		limitedDescriptor(descriptor)
			.split(whereSeparator: \.isWhitespace)
			.joined(separator: " ")
	}

	public static func descriptor(for slot: Int, in descriptors: [String]) -> String {
		let index = slot - slots.lowerBound
		return descriptors.indices.contains(index) ? sanitizedDescriptor(descriptors[index]) : ""
	}
}
