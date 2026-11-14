//
//  WebPageFuzzTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 11/11/2026.
//

import ErgoShare
import Foundation
import Testing

/// Pages come from anywhere, and plenty of them are broken. Whatever the HTML, reading it may not crash or hang, and
/// what comes out has to be text and never markup.
struct WebPageFuzzTests {
	static let pieces = [
		"<p>", "</p>", "<div>", "</div>", "<article>", "</article>", "<main>", "</main>", "<script>", "</script>", "<style>", "</style>",
		"<title>", "</title>", "<nav>", "</nav>", "<br>", "<br/>", "<a href=\"x\">", "</a>", "<!--", "-->", "<![CDATA[", "]]>",
		"<", ">", "</", "/>", "=", "\"", "'", "&amp;", "&#8217;", "&#x;", "&#99999999999;", "&nosuch;", "&", ";",
		"<p class='a>b'>", "<h1>", "</h1>", "<li>", "</li>", "<svg>", "</svg>", "<noscript>", "</noscript>", "<P>", "</ARTICLE>",
		"It rained all night, and the ground was wet by morning.", "Menu", " ", "\n", "é", "👨‍👩‍👧", "\u{0}",
	]

	private static func html(seed: UInt64) -> String {
		var random = SeededRandom(seed: seed)
		return (0 ..< Int.random(in: 0 ... 60, using: &random)).map { _ in pieces.randomElement(using: &random)! }.joined()
	}

	@Test(arguments: 0 ..< 600 as Range<UInt64>)
	func anyHTMLReads(seed: UInt64) {
		let html = Self.html(seed: seed)

		let page = WebPageText(html: html)

		#expect(page == WebPageText(html: html), "\(html.debugDescription)")
		#expect(page.text == page.text.trimmingCharacters(in: .whitespacesAndNewlines), "\(html.debugDescription)")
		#expect(!page.text.contains("\n\n\n"), "\(html.debugDescription)")
	}

	/// With no `<` or `>` in the words themselves, none may be left in what's read
	@Test(arguments: 1000 ..< 1300 as Range<UInt64>)
	func noTagsAreLeftInTheText(seed: UInt64) throws {
		var random = SeededRandom(seed: seed)
		let tags = ["p", "div", "span", "b", "i", "a", "li", "ul", "h2", "section", "blockquote", "em"]
		var html = "<html><head><title>A page</title></head><body>"
		for _ in 0 ..< Int.random(in: 1 ... 30, using: &random) {
			let tag = try #require(tags.randomElement(using: &random))
			html += "<\(tag) class=\"x\" data-n='\(Int.random(in: 0 ... 9, using: &random))'>The ground was wet by morning."
			if Bool.random(using: &random) {
				html += "</\(tag)>"
			}
		}

		let page = WebPageText(html: html)

		#expect(page.title == "A page")
		#expect(!page.text.contains("<") && !page.text.contains(">") && !page.text.contains("class="), "\(page.text)")
		#expect(page.text.contains("The ground was wet by morning."))
	}

	// MARK: - As big as it gets

	@Test(arguments: ["div", "p", "article", "main", "span", "ul", "table", "blockquote"])
	func deepNestingReads(tag: String) {
		let depth = 50000
		let page = WebPageText(html: String(repeating: "<\(tag)>", count: depth) + "The ground was wet by morning." + String(repeating: "</\(tag)>", count: depth))
		#expect(page.text == "The ground was wet by morning.")

		_ = WebPageText(html: String(repeating: "<\(tag)>", count: depth))
		_ = WebPageText(html: String(repeating: "</\(tag)>", count: depth))
	}

	@Test func aVeryLargePageReads() {
		let paragraph = "<p>It rained all night, and the ground was wet by morning.</p>\n"
		let page = WebPageText(html: "<article>" + String(repeating: paragraph, count: 20000) + "</article>")
		#expect(page.text.components(separatedBy: "\n\n").count == 20000)
	}

	@Test func whatNeverClosesStillReads() {
		let words = String(repeating: "word ", count: 20000)
		for opener in ["<script>", "<style>", "<!--", "<p class=\"", "<a href='", "<title>", "<", "&"] {
			_ = WebPageText(html: "<p>Before it.</p>" + opener + words)
		}
	}

	@Test func aThousandAmpersandsRead() {
		let page = WebPageText(html: "<p>" + String(repeating: "&", count: 100_000) + ".</p>")
		#expect(page.text.count == 100_001)
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
