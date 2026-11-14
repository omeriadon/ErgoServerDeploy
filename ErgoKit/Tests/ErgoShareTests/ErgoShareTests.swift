//
//  ErgoShareTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 7/11/2026.
//

import ErgoShare
import Foundation
import Testing

struct WebPageTextTests {
	private let paragraph = "This paragraph is long enough to count as what the page is really about, and it goes on for a while so that the region around it passes the bar for being worth reading on its own, which takes a couple of hundred characters."

	@Test func titleAndParagraphs() {
		let page = WebPageText(html: "<html><head><title>A &amp; B</title></head><body><p>First sentence here.</p><p>Second <em>one</em> here.</p></body></html>")
		#expect(page.title == "A & B")
		#expect(page.text == "First sentence here.\n\nSecond one here.")
	}

	@Test func leavesOutWhatIsNotText() {
		let page = WebPageText(html: """
		<!doctype html><!-- <p>A comment.</p> -->
		<style>p { color: red; }</style>
		<script>let a = "<p>Not text.</p>";</script>
		<nav><ul><li>Home page link here now.</li></ul></nav>
		<SCRIPT>let b = 1;</SCRIPT>
		<p>What it says.</p>
		<footer><div><footer>Nested.</footer>Copyright notice is here.</div></footer>
		""")
		#expect(page.text == "What it says.")
	}

	@Test func prefersTheLongestArticle() {
		let page = WebPageText(html: """
		<p>Stray words outside any article.</p>
		<article><p>A short teaser, not the story.</p></article>
		<article><p>\(paragraph)</p></article>
		""")
		#expect(page.text == paragraph)
	}

	@Test func mainWhenThereIsNoArticle() {
		let page = WebPageText(html: "<div>Stray words outside of main.</div><main><p>\(paragraph)</p></main>")
		#expect(page.text == paragraph)
	}

	@Test func wholePageWhenTheArticleIsATeaser() {
		let page = WebPageText(html: "<article><p>A short teaser.</p></article><p>\(paragraph)</p>")
		#expect(page.text == "A short teaser.\n\n\(paragraph)")
	}

	@Test func dropsScrapsOfMenus() {
		let page = WebPageText(html: "<div>Subscribe</div><div>By A. Writer</div><p>A full sentence stays in.</p><p>Short but finished.</p>")
		#expect(page.text == "A full sentence stays in.\n\nShort but finished.")
	}

	@Test func entities() {
		let page = WebPageText(html: "<p>It&#39;s &#x201C;fine&#x201D; &mdash; 1 &lt; 2 &unknown; AT&T.</p>")
		#expect(page.text == "It's “fine” — 1 < 2 &unknown; AT&T.")
	}

	@Test func badHTMLStillReads() {
		let page = WebPageText(html: "<p title=\"a > b\">Is a < b really true here?<p>Unclosed paragraphs are fine.")
		#expect(page.text == "Is a < b really true here?\n\nUnclosed paragraphs are fine.")
		#expect(WebPageText(html: "<").text.isEmpty)
		#expect(WebPageText(html: "").text.isEmpty)
		#expect(WebPageText(html: "<script>never closed").text.isEmpty)
	}

	@Test func nonASCIITextSurvives() {
		let page = WebPageText(html: "<p>Café crème — naïve résumé, 日本語も読めます.</p>")
		#expect(page.text == "Café crème — naïve résumé, 日本語も読めます.")
	}
}

struct SharedItemTests {
	private let link = URL(string: "https://example.com/a")!

	@Test func linkWithItsTitle() {
		#expect(SharedItem.Content(url: link, text: " A Title ") == .link(link, title: "A Title"))
		#expect(SharedItem.Content(url: link, text: nil) == .link(link, title: nil))
		#expect(SharedItem.Content(url: link, text: link.absoluteString) == .link(link, title: nil))
	}

	@Test func longTextBesideALinkIsTheSelection() {
		let selected = String(repeating: "word ", count: 100).trimmingCharacters(in: .whitespaces)
		#expect(SharedItem.Content(url: link, text: selected) == .text(selected))
	}

	@Test func textThatIsOnlyALinkIsALink() {
		#expect(SharedItem.Content(url: nil, text: " https://example.com/a\n") == .link(link, title: nil))
		#expect(SharedItem.Content(url: nil, text: "All men are mortal.") == .text("All men are mortal."))
	}

	@Test func nothingUsable() {
		#expect(SharedItem.Content(url: nil, text: "  \n") == nil)
		#expect(SharedItem.Content(url: URL(fileURLWithPath: "/tmp/a.pdf"), text: nil) == nil)
	}

	@Test func cutEndsOnASentenceThenAWord() {
		#expect(SharedText.cut("Short.", to: 100) == "Short.")
		#expect(SharedText.cut("One two three. Four five six seven", to: 20) == "One two three.")
		#expect(SharedText.cut("One two three four five six seven", to: 20) == "One two three four")
		#expect(SharedText.cut(String(repeating: "a", count: 30), to: 20).count == 20)
	}

	@Test func inboxHandsAnItemOverOnce() throws {
		let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }

		let inbox = SharedItemInbox(directory: directory)
		#expect(inbox.take() == nil)

		try inbox.put(SharedItem(content: .text("Old."), action: .ask))
		let item = SharedItem(content: .link(link, title: "A Title"), action: .breakDown)
		try inbox.put(item)

		#expect(inbox.take() == item)
		#expect(inbox.take() == nil)
	}
}
