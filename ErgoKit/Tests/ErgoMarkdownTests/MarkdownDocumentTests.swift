//
//  MarkdownDocumentTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 6/11/2026.
//

import ErgoMarkdown
import Foundation
import Testing

struct MarkdownDocumentTests {
	private func text(_ attributed: AttributedString) -> String {
		String(attributed.characters)
	}

	@Test func headingsAndParagraphs() {
		let blocks = MarkdownDocument("# Title\n\nSome **bold** words.\n\nMore.").blocks
		#expect(blocks.count == 3)
		guard case let .heading(level, title) = blocks[0], case let .paragraph(body) = blocks[1] else {
			Issue.record("Expected a heading and a paragraph, found \(blocks)")
			return
		}
		#expect(level == 1)
		#expect(text(title) == "Title")
		#expect(text(body) == "Some bold words.")
		#expect(body.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized })
	}

	@Test func linksSurvive() throws {
		let url = "ergo://intent/open-library-entry?category=fallacies&id=straw-man"
		let blocks = MarkdownDocument("That's a [straw man](\(url)).").blocks
		guard case let .paragraph(body) = try #require(blocks.first) else {
			Issue.record("Expected a paragraph")
			return
		}
		#expect(body.runs.compactMap(\.link).first?.absoluteString == url)
	}

	@Test func codeBlocksKeepTheirLines() {
		let blocks = MarkdownDocument("```swift\nlet a = 1\nlet b = 2\n```").blocks
		#expect(blocks == [.code(language: "swift", text: "let a = 1\nlet b = 2")])
	}

	@Test func listsNestAndKeepTheirOrder() {
		let blocks = MarkdownDocument("1. one\n2. two\n   - inner\n3. three").blocks
		guard case let .list(ordered, items) = blocks.first else {
			Issue.record("Expected a list, found \(blocks)")
			return
		}
		#expect(ordered)
		#expect(items.count == 3)
		#expect(items[1].count == 2)
		guard case let .list(innerOrdered, inner) = items[1][1] else {
			Issue.record("Expected a nested list, found \(items[1])")
			return
		}
		#expect(!innerOrdered)
		#expect(inner.count == 1)
	}

	@Test func quotesHoldBlocks() {
		let blocks = MarkdownDocument("> quoted\n>\n> again").blocks
		guard case let .quote(inner) = blocks.first else {
			Issue.record("Expected a quote, found \(blocks)")
			return
		}
		#expect(inner.count == 2)
	}

	@Test func tablesHaveAHeaderAndRows() {
		let blocks = MarkdownDocument("| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |").blocks
		guard case let .table(header, rows) = blocks.first else {
			Issue.record("Expected a table, found \(blocks)")
			return
		}
		#expect(header.map(text) == ["a", "b"])
		#expect(rows.map { $0.map(text) } == [["1", "2"], ["3", "4"]])
	}

	@Test func rules() {
		let blocks = MarkdownDocument("above\n\n---\n\nbelow").blocks
		#expect(blocks.count == 3)
		#expect(blocks[1] == .rule)
	}

	@Test func textStillArrivingDoesNotBreak() {
		for partial in ["**bo", "[a link](ergo://int", "```swi", "| a | b", "1. "] {
			_ = MarkdownDocument(partial).blocks
		}
		#expect(MarkdownDocument("").blocks.isEmpty)
	}
}

struct MarkdownMathTests {
	private func plain(_ attributed: AttributedString) -> String {
		String(attributed.characters)
	}

	private func text(_ source: String) -> String {
		LaTeX.runs(source).map(\.text).joined()
	}

	@Test func logicReadsAsSymbols() {
		#expect(text(#"P \to Q"#) == "P → Q")
		#expect(text(#"(P \land Q) \lor \neg R"#) == "(P ∧ Q) ∨ ¬R")
		#expect(text(#"\forall x \, P(x) \rightarrow \exists y \, Q(y)"#) == "∀x P(x) → ∃y Q(y)")
		#expect(text(#"\therefore Q"#) == "∴ Q")
		#expect(text(#"P \vdash Q"#) == "P ⊢ Q")
		#expect(text("P → Q") == "P → Q")
	}

	@Test func scriptsAreMarked() {
		#expect(LaTeX.runs("x_1") == [LaTeX.Run("x"), LaTeX.Run("1", script: -1)])
		#expect(LaTeX.runs("x^{n+1}") == [LaTeX.Run("x"), LaTeX.Run("n + 1", script: 1)])
	}

	@Test func wordsKeepTheirSpaces() {
		#expect(text(#"\text{it rains} \to Q"#) == "it rains → Q")
	}

	@Test func fractionsAndRootsStayOnOneLine() {
		#expect(text(#"\frac{a}{b}"#) == "a/b")
		#expect(text(#"\frac{a+1}{b}"#) == "(a + 1)/b")
		#expect(text(#"\sqrt{2}"#) == "√2")
	}

	@Test func whatItDoesntKnowStays() {
		#expect(text(#"\madeup x"#) == #"\madeupx"#)
	}

	@Test func oddInputDoesNotBreak() {
		for source in ["", "\\", "x^", "{", "}", "\\frac{a", "\\text{", "_", "^^", "\\left."] {
			_ = LaTeX.runs(source)
		}
	}

	@Test func inlineMathKeepsItsUnderscoresAndBackslashes() throws {
		let blocks = MarkdownDocument(#"So $x_1 \to y_2$ and *more*."#).blocks
		guard case let .paragraph(body) = try #require(blocks.first) else {
			Issue.record("Expected a paragraph, found \(blocks)")
			return
		}
		#expect(plain(body) == "So x1 → y2 and more.")
		#expect(body.runs.contains { $0[MarkdownMathAttribute.self] == -1 })
		#expect(body.runs.contains { $0.inlinePresentationIntent == .emphasized })
	}

	@Test func everyWayOfWritingMath() throws {
		for source in [#"$P \to Q$"#, #"\(P \to Q\)"#] {
			guard case let .paragraph(body) = try #require(MarkdownDocument(source).blocks.first) else {
				Issue.record("Expected a paragraph for \(source)")
				continue
			}
			#expect(plain(body) == "P → Q")
		}
		for source in ["$$P \\to Q$$", "\\[P \\to Q\\]", "$$\nP \\to Q\n$$"] {
			guard case let .math(body) = try #require(MarkdownDocument(source).blocks.first) else {
				Issue.record("Expected display maths for \(source)")
				continue
			}
			#expect(plain(body) == "P → Q")
		}
	}

	@Test func displayMathBetweenParagraphs() {
		let blocks = MarkdownDocument("Before\n\n$$P$$\n\nAfter").blocks
		#expect(blocks.count == 3)
		if case .math = blocks[1] {} else {
			Issue.record("Expected maths, found \(blocks[1])")
		}
	}

	@Test func displayMathStillBeingWrittenIsMath() throws {
		guard case let .math(body) = try #require(MarkdownDocument("$$P \\to").blocks.first) else {
			Issue.record("Expected maths")
			return
		}
		#expect(plain(body) == "P →")
	}

	@Test func pricesAreNotMath() throws {
		guard case let .paragraph(body) = try #require(MarkdownDocument("It costs $5 and $10 today").blocks.first) else {
			Issue.record("Expected a paragraph")
			return
		}
		#expect(plain(body) == "It costs $5 and $10 today")
	}

	@Test func codeIsNotMath() {
		#expect(MarkdownDocument("```\n$x$\n```").blocks == [.code(language: nil, text: "$x$")])
		if case let .paragraph(body)? = MarkdownDocument("Use `$x$` here").blocks.first {
			#expect(plain(body) == "Use $x$ here")
		} else {
			Issue.record("Expected a paragraph")
		}
	}

	@Test func mathInListsAndTables() throws {
		guard case let .list(_, items) = try #require(MarkdownDocument("- $P \\land Q$").blocks.first), case let .paragraph(body)? = items.first?.first else {
			Issue.record("Expected a list")
			return
		}
		#expect(plain(body) == "P ∧ Q")

		guard case let .table(header, _) = try #require(MarkdownDocument("| $P$ | b |\n|---|---|\n| 1 | 2 |").blocks.first) else {
			Issue.record("Expected a table")
			return
		}
		#expect(plain(header[0]) == "P")
	}
}
