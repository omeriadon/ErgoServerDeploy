//
//  TextPartsFuzzTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 11/11/2026.
//

import ErgoTranslation
import Foundation
import Testing

/// Whatever is pasted, every character that isn't a space comes out in some part, in order, and every part fits
struct TextPartsFuzzTests {
	static let pieces = [
		"It rained.", "So the ground is wet!", "Is it?", "word", "a", "e.g.", "3.14", "...", "?!", "\n", "\n\n", "\n\n\n", " ", "  ", "\t",
		"é", "👨‍👩‍👧", "。", "supercalifragilisticexpialidocious", ".", "!", "\r\n", "\u{00A0}",
	]

	private static func visible(_ text: String) -> String {
		String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
	}

	@Test(arguments: 0 ..< 500 as Range<UInt64>)
	func nothingIsLostAndEveryPartFits(seed: UInt64) {
		var random = SeededRandom(seed: seed)
		let text = (0 ..< Int.random(in: 0 ... 200, using: &random)).map { _ in Self.pieces.randomElement(using: &random)! }.joined()
		let limit = Int.random(in: 1 ... 120, using: &random)

		let parts = TextParts.split(text, characterLimit: limit)

		#expect(parts.allSatisfy { $0.count <= limit }, "limit \(limit): \(text.debugDescription)")
		#expect(parts.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }, "limit \(limit): \(text.debugDescription)")
		#expect(Self.visible(parts.joined()) == Self.visible(text), "limit \(limit): \(text.debugDescription)")
		#expect(parts == TextParts.split(text, characterLimit: limit))
	}

	@Test func textThatFitsIsOnePart() {
		let text = String(repeating: "It rained. ", count: 100).trimmingCharacters(in: .whitespaces)
		#expect(TextParts.split(text, characterLimit: text.count) == [text])
		#expect(TextParts.split(text, characterLimit: text.count - 1).count == 2)
	}

	@Test func nothingToSplitIsNoParts() {
		#expect(TextParts.split("").isEmpty)
		#expect(TextParts.split(" \n\n \t \n").isEmpty)
	}

	@Test func aBookIsSplitWithoutLosingAnything() {
		let paragraph = String(repeating: "The ground was wet by morning, so it had rained. ", count: 40)
		let text = Array(repeating: paragraph, count: 600).joined(separator: "\n\n")

		let parts = TextParts.split(text)

		#expect(parts.count > 1)
		#expect(parts.allSatisfy { $0.count <= EnglishValidator.characterLimit })
		#expect(Self.visible(parts.joined()).count == Self.visible(text).count)
	}

	@Test func theValidatorNeverBreaksOnWhatIsPasted() {
		for text in ["", " ", "\u{0}", String(repeating: "a", count: EnglishValidator.characterLimit + 1), String(repeating: "👨‍👩‍👧", count: 20000), "\u{202E}reversed", String(repeating: "\n", count: 100_000)] {
			_ = EnglishValidator.problem(with: text)
		}
		let sentence = "It rained. "
		let fits = String(repeating: sentence, count: EnglishValidator.characterLimit / sentence.count)
		#expect(EnglishValidator.problem(with: fits) == nil)
		#expect(EnglishValidator.problem(with: fits + String(repeating: "a", count: EnglishValidator.characterLimit)) != nil)
	}
}

/// SplitMix64, so a seed that fails can be run again and fails the same way
private struct SeededRandom: RandomNumberGenerator {
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
