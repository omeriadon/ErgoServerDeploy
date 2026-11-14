//
//  LogicInputVocabulary.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import Foundation

public struct LogicInputVocabulary: Sendable {
	public let letters: [String]

	private let entries: [Character: LogicKeyboardEntry]

	/// Also maps the other case of each letter, so a hardware keyboard or paste doesn't need to match exactly
	private let lenientEntries: [Character: LogicKeyboardEntry]

	public init(letters: [String]) {
		self.letters = LogicLetters.resolved(letters)

		var entries: [Character: LogicKeyboardEntry] = [:]
		for entry in LogicKeyboardEntry.variables + LogicKeyboardEntry.symbolEntries {
			if let character = entry.glyph(letters: self.letters).first {
				entries[character] = entry
			}
		}
		self.entries = entries

		var lenientEntries = entries
		for entry in LogicKeyboardEntry.variables {
			let glyph = entry.glyph(letters: self.letters)
			for character in glyph.lowercased() + glyph.uppercased() where lenientEntries[character] == nil {
				lenientEntries[character] = entry
			}
		}
		self.lenientEntries = lenientEntries
	}

	public func accepts(_ text: String) -> Bool {
		text.allSatisfy { entries[$0] != nil }
	}

	public func entry(for character: Character) -> LogicKeyboardEntry? {
		entries[character]
	}

	/// Maps typed or pasted text onto entries, dropping anything the keyboard can't produce
	public func entries(in text: String) -> [LogicKeyboardEntry] {
		text.compactMap { lenientEntries[$0] }
	}

	public func text(for entries: [LogicKeyboardEntry]) -> String {
		entries.map { $0.glyph(letters: letters) }.joined()
	}

	public func normalized(_ text: String) -> String {
		self.text(for: entries(in: text))
	}
}
