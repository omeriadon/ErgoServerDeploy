//
//  MarkdownFuzzTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 11/11/2026.
//

import ErgoMarkdown
import Foundation
import Testing

/// Answers arrive a few characters at a time and come from a model, so the markdown is whatever it is. None of it may
/// crash or hang, and the same text always has to come out as the same blocks.
struct MarkdownFuzzTests {
	static let pieces = [
		"# ", "## ", "###### ", "**", "*", "_", "~~", "`", "```", "```swift\n", "$", "$$", "\\(", "\\)", "\\[", "\\]",
		"|", "---", "| a | b |\n|---|---|\n", "- ", "1. ", "   - ", "> ", "> > ", "[", "](", ")", "![", "<", ">", "&amp;",
		"\n", "\n\n", " ", "\t", "\\", "\\frac{", "\\sqrt{", "{", "}", "^", "_{", "\\forall", "\\to", "\\land",
		"word", "It rained.", "ergo://library/fallacies/straw-man", "https://example.com", "$5", "é", "👨‍👩‍👧", "\u{200B}", "\u{0301}", "\r\n",
	]

	private static func text(seed: UInt64, pieces count: ClosedRange<Int>) -> String {
		var random = SeededRandom(seed: seed)
		return (0 ..< Int.random(in: count, using: &random)).map { _ in pieces.randomElement(using: &random)! }.joined()
	}

	@Test(arguments: 0 ..< 500 as Range<UInt64>)
	func anythingReadsTheSameEveryTime(seed: UInt64) {
		let text = Self.text(seed: seed, pieces: 0 ... 40)
		#expect(MarkdownDocument(text) == MarkdownDocument(text), "\(text.debugDescription)")
	}

	/// What the view is given while an answer streams: every length of it, one after the other
	@Test(arguments: 1000 ..< 1060 as Range<UInt64>)
	func everyPrefixOfAnAnswerReads(seed: UInt64) {
		let text = Self.text(seed: seed, pieces: 10 ... 30)
		for end in text.indices {
			_ = MarkdownDocument(String(text[..<end]))
		}
	}

	@Test(arguments: 2000 ..< 2300 as Range<UInt64>)
	func anyMathsReads(seed: UInt64) {
		var random = SeededRandom(seed: seed)
		let pieces = ["\\frac", "\\sqrt", "{", "}", "^", "_", "\\", "\\land", "\\text{", "\\mathbb{R}", "x", "1", " ", "\\left(", "\\right)", "&", "\\\\", "é", "\\unknown", "$"]
		let source = (0 ..< Int.random(in: 0 ... 30, using: &random)).map { _ in pieces.randomElement(using: &random)! }.joined()

		let runs = LaTeX.runs(source)

		#expect(runs == LaTeX.runs(source), "\(source)")
		#expect(runs.allSatisfy { !$0.text.isEmpty && (-1 ... 1).contains($0.script) }, "\(source)")
	}

	// MARK: - As big as it gets

	@Test(arguments: ["> ", "- ", "  ", "* ", "1. "])
	func deepNestingReads(opener: String) {
		// What used to crash: every level of quote was a level of the stack
		let document = MarkdownDocument(String(repeating: opener, count: 2000) + "deep")
		#expect(document == MarkdownDocument(String(repeating: opener, count: 2000) + "deep"))
		_ = MarkdownDocument((0 ..< 300).map { String(repeating: "  ", count: $0) + "- item" }.joined(separator: "\n"))
	}

	@Test(arguments: ["\\frac{", "\\sqrt{", "{", "^{", "_{", "\\text{", "\\left("])
	func deeplyNestedMathsReads(opener: String) {
		for depth in [10, 100, 1000, 20000] {
			_ = LaTeX.runs(String(repeating: opener, count: depth) + "x" + String(repeating: "}", count: depth))
			_ = LaTeX.runs(String(repeating: opener, count: depth))
			_ = MarkdownDocument("$" + String(repeating: opener, count: depth) + "x$")
		}
	}

	/// Every paragraph holds maths, which once made this take as long as the square of the paragraphs
	@Test func aVeryLongAnswerReads() {
		let paragraph = "It **rained**, so the ground is *wet* [see](ergo://library/fallacies/straw-man) and $X \\to Y$.\n\n"
		let start = ContinuousClock.now
		let document = MarkdownDocument(String(repeating: paragraph, count: 3000))
		#expect(document.blocks.count == 3000)
		#expect(ContinuousClock.now - start < .seconds(10))
	}

	@Test func eachPlaceholderGetsItsOwnMaths() {
		let document = MarkdownDocument("$A$ then $B$, and $A$ again.\n\n$$C$$\n\nNot maths: \u{E000}7\u{E001} stays.")
		let texts = document.blocks.map { block -> String in
			switch block {
				case let .paragraph(text), let .math(text): String(text.characters)
				default: ""
			}
		}
		#expect(texts.count == 3)
		#expect(!texts[0].contains("\u{E000}"))
		#expect(texts[0].contains("then") && texts[0].contains("again."))
		if case .math = document.blocks[1] {} else {
			Issue.record("Expected $$C$$ on its own to be a maths block")
		}
		#expect(texts[2].contains("\u{E000}7\u{E001}"))
	}

	@Test func whatIsNestedTooFarIsStillThere() {
		func words(_ blocks: [MarkdownDocument.Block]) -> String {
			blocks.map { block in
				switch block {
					case let .paragraph(text), let .heading(_, text), let .math(text): String(text.characters)
					case let .quote(inner): words(inner)
					case let .list(_, items): items.map(words).joined()
					default: ""
				}
			}.joined()
		}
		#expect(words(MarkdownDocument(String(repeating: "> ", count: 30) + "deep").blocks) == "deep")
		#expect(words(MarkdownDocument(String(repeating: "> ", count: 300) + "deep").blocks) == "deep")
	}

	@Test func mathsNestedTooFarStaysAsWritten() {
		let shallow = String(repeating: "{", count: 10) + "x" + String(repeating: "}", count: 10)
		#expect(LaTeX.runs(shallow).map(\.text) == ["x"])

		let deep = String(repeating: "{", count: 500) + "x" + String(repeating: "}", count: 500)
		#expect(LaTeX.runs(deep).map(\.text).joined().contains("x"))
	}

	@Test func unclosedEverythingReads() {
		for opener in ["```", "$$", "\\[", "\\(", "**", "[", "| a | b |\n|---|", "<details>", "<!--"] {
			let document = MarkdownDocument("Before\n\n" + opener + "\nafter " + String(repeating: "more ", count: 500))
			#expect(!document.blocks.isEmpty, "\(opener)")
		}
	}

	@Test func nothingButControlCharactersReads() {
		_ = MarkdownDocument(String(repeating: "\u{0}", count: 100))
		_ = MarkdownDocument(String((0 ..< 2000).compactMap { Unicode.Scalar($0).map(Character.init) }))
		_ = LaTeX.runs(String((0 ..< 2000).compactMap { Unicode.Scalar($0).map(Character.init) }))
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
