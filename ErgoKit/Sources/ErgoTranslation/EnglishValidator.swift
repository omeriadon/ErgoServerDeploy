//
//  EnglishValidator.swift
//  Ergo
//
//  Created by Adon Omeri on 5/11/2026.
//

import Foundation
#if canImport(NaturalLanguage)
	import NaturalLanguage
#endif

/// Turns away text that obviously isn't English sentences, before spending a model call on it
public enum EnglishValidator {
	public static let characterLimit = 50_000

	public static func problem(with english: String) -> String? {
		let text = english.trimmingCharacters(in: .whitespacesAndNewlines)
		let characters = text.filter { !$0.isWhitespace }
		let words = text.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).filter { $0.contains(where: \.isLetter) }

		if text.isEmpty {
			return "Expected English to translate"
		}
		if text.count > characterLimit {
			return "Too long to translate, expected at most \(characterLimit) characters"
		}
		if Double(characters.filter(\.isLetter).count) < Double(characters.count) * 0.6 {
			return "Expected English sentences, found mostly symbols"
		}
		if words.count < 2 {
			return "Expected at least one full sentence"
		}

		#if canImport(NaturalLanguage)
			// Too unreliable on a few words to judge
			if words.count >= 4 {
				let recognizer = NLLanguageRecognizer()
				recognizer.processString(text)
				let english = recognizer.languageHypotheses(withMaximum: 3)[.english] ?? 0
				if english < 0.5 {
					return "Expected English"
				}
			}
		#endif

		return nil
	}
}
