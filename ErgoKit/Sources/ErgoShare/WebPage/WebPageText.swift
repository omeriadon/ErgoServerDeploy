//
//  WebPageText.swift
//  ErgoKit
//
//  Created by Adon Omeri on 7/11/2026.
//

import Foundation

/// The readable text of a web page, as paragraphs. It's a simple scan of the HTML, not a browser: nothing runs, so a page
/// that builds itself with JavaScript has little to find.
public struct WebPageText: Hashable, Sendable {
	public let title: String?

	/// Paragraphs separated by blank lines. Empty when the page has nothing to read.
	public let text: String

	/// Shorter than this, an `<article>` or `<main>` is a teaser and the whole page is the better bet
	static let enoughCharacters = 200

	public init(html: String) {
		var scanner = Scanner(html: html)
		scanner.run()
		title = scanner.title

		let regions = scanner.articles.closed.isEmpty ? scanner.mains.closed : scanner.articles.closed
		let longest = regions
			.map { scanner.blocks[$0] }
			.max { $0.joinedCount < $1.joinedCount }
		let blocks = if let longest, longest.joinedCount >= Self.enoughCharacters {
			Array(longest)
		} else {
			scanner.blocks
		}
		text = blocks.filter(Self.isReadable).joined(separator: "\n\n")
	}

	/// Drops what's left of menus, bylines and buttons: a few words that don't end like a sentence
	static func isReadable(_ block: String) -> Bool {
		if let last = block.last, ".!?:\"”".contains(last) {
			return true
		}
		return block.split(whereSeparator: \.isWhitespace).count >= 4
	}
}

extension ArraySlice<String> {
	var joinedCount: Int {
		reduce(0) { $0 + $1.count }
	}
}

// MARK: - Scanner

/// Which blocks fall inside each outermost `<article>`, or each outermost `<main>`
struct Region {
	var open: (start: Int, depth: Int)?
	private(set) var closed: [Range<Int>] = []

	mutating func tag(isClosing: Bool, at block: Int) {
		if !isClosing {
			open = open.map { ($0.start, $0.depth + 1) } ?? (block, 1)
		} else if let current = open {
			if current.depth == 1 {
				finish(at: block)
			} else {
				open = (current.start, current.depth - 1)
			}
		}
	}

	mutating func finish(at block: Int) {
		if let current = open {
			closed.append(current.start ..< block)
			open = nil
		}
	}
}
