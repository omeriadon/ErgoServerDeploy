//
//  WebPageScanner.swift
//  Ergo
//
//  Created by Adon Omeri on 8/11/2026.
//

import Foundation

struct Scanner {
	/// What's inside these is never text, and they can't nest, so they're jumped over to their closing tag
	static let rawElements: Set<String> = ["script", "style", "noscript", "template", "textarea", "iframe", "svg", "canvas"]

	/// Page furniture, which can nest
	static let skippedElements: Set<String> = ["nav", "header", "footer", "aside", "button", "select", "menu", "dialog"]

	/// What starts a new paragraph
	static let blockElements: Set<String> = [
		"address", "article", "blockquote", "body", "br", "dd", "details", "div", "dl", "dt", "figcaption", "figure",
		"h1", "h2", "h3", "h4", "h5", "h6", "hr", "li", "main", "ol", "p", "pre", "section", "summary", "table", "tr", "ul",
	]

	let bytes: [UInt8]
	var index = 0

	var paragraph = ""
	var skipping: (name: String, depth: Int)?

	private(set) var title: String?
	private(set) var blocks: [String] = []
	private(set) var articles = Region()
	private(set) var mains = Region()

	init(html: String) {
		bytes = Array(html.utf8)
	}

	mutating func run() {
		while index < bytes.count {
			if bytes[index] != UInt8(ascii: "<") {
				let end = bytes[index...].firstIndex(of: UInt8(ascii: "<")) ?? bytes.count
				if skipping == nil {
					paragraph += HTMLEntities.decoded(string(index ..< end))
				}
				index = end
			} else if starts(with: "<!--") {
				index = position(after: "-->", from: index + 4) ?? bytes.count
			} else if let tag = readTag() {
				handle(tag)
			} else {
				// A "<" that doesn't open a tag, like "a < b"
				if skipping == nil {
					paragraph += "<"
				}
				index += 1
			}
		}
		endParagraph()
		articles.finish(at: blocks.count)
		mains.finish(at: blocks.count)
	}

	// MARK: - Tags

	struct Tag {
		let name: String
		let isClosing: Bool
		let isSelfClosing: Bool
	}

	/// Reads the tag at `index` and moves past it. Quotes are followed, since an attribute's value can hold a ">".
	private mutating func readTag() -> Tag? {
		var cursor = index + 1
		guard cursor < bytes.count else { return nil }

		// <!doctype> and <?xml?> are tags with no name worth keeping
		if bytes[cursor] == UInt8(ascii: "!") || bytes[cursor] == UInt8(ascii: "?") {
			index = position(after: ">", from: cursor) ?? bytes.count
			return Tag(name: "", isClosing: false, isSelfClosing: true)
		}

		let isClosing = bytes[cursor] == UInt8(ascii: "/")
		if isClosing {
			cursor += 1
		}

		let nameStart = cursor
		while cursor < bytes.count, isNameByte(bytes[cursor]) {
			cursor += 1
		}
		guard cursor > nameStart else { return nil }
		let name = string(nameStart ..< cursor).lowercased()

		var quote: UInt8?
		while cursor < bytes.count {
			let byte = bytes[cursor]
			if let open = quote {
				if byte == open {
					quote = nil
				}
			} else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
				quote = byte
			} else if byte == UInt8(ascii: ">") {
				break
			}
			cursor += 1
		}

		let isSelfClosing = cursor > 0 && cursor < bytes.count && bytes[cursor - 1] == UInt8(ascii: "/")
		index = min(cursor + 1, bytes.count)
		return Tag(name: name, isClosing: isClosing, isSelfClosing: isSelfClosing)
	}

	private mutating func handle(_ tag: Tag) {
		if let current = skipping {
			guard tag.name == current.name, !tag.isSelfClosing else { return }
			let depth = current.depth + (tag.isClosing ? -1 : 1)
			skipping = depth == 0 ? nil : (current.name, depth)
			return
		}

		if !tag.isClosing, tag.name == "title" {
			let end = closingTag("title")
			if title == nil {
				let found = collapsed(HTMLEntities.decoded(string(index ..< end.start)))
				title = found.isEmpty ? nil : found
			}
			index = end.after
		} else if !tag.isClosing, Self.rawElements.contains(tag.name) {
			if !tag.isSelfClosing {
				index = closingTag(tag.name).after
			}
		} else if !tag.isClosing, !tag.isSelfClosing, Self.skippedElements.contains(tag.name) {
			skipping = (tag.name, 1)
		} else if tag.name == "article" {
			endParagraph()
			articles.tag(isClosing: tag.isClosing, at: blocks.count)
		} else if tag.name == "main" {
			endParagraph()
			mains.tag(isClosing: tag.isClosing, at: blocks.count)
		} else if Self.blockElements.contains(tag.name) {
			endParagraph()
		} else if tag.name == "td" || tag.name == "th" {
			paragraph += " "
		}
	}

	private mutating func endParagraph() {
		let text = collapsed(paragraph)
		paragraph = ""
		if !text.isEmpty {
			blocks.append(text)
		}
	}

	func collapsed(_ text: String) -> String {
		text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
	}

	// MARK: - Bytes

	func isNameByte(_ byte: UInt8) -> Bool {
		switch byte {
			case UInt8(ascii: "a") ... UInt8(ascii: "z"), UInt8(ascii: "A") ... UInt8(ascii: "Z"), UInt8(ascii: "0") ... UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: ":"):
				true
			default:
				false
		}
	}

	func string(_ range: Range<Int>) -> String {
		String(decoding: bytes[range], as: UTF8.self)
	}

	func starts(with text: String) -> Bool {
		bytes[index...].starts(with: text.utf8)
	}

	func position(after text: String, from start: Int) -> Int? {
		let needle = Array(text.utf8)
		var cursor = start
		while cursor + needle.count <= bytes.count {
			if bytes[cursor] == needle[0], bytes[cursor ..< cursor + needle.count].elementsEqual(needle) {
				return cursor + needle.count
			}
			cursor += 1
		}
		return nil
	}

	/// Where `</name` starts and where its tag ends, whatever its case. The end of the page when it's never closed.
	func closingTag(_ name: String) -> (start: Int, after: Int) {
		let needle = Array("</\(name)".utf8)
		var cursor = index
		while cursor + needle.count <= bytes.count {
			if bytes[cursor] == needle[0], bytes[cursor + 1] == needle[1] {
				let matches = zip(bytes[cursor ..< cursor + needle.count], needle).allSatisfy { lowercased($0) == $1 }
				if matches {
					let after = bytes[cursor...].firstIndex(of: UInt8(ascii: ">")).map { $0 + 1 } ?? bytes.count
					return (cursor, after)
				}
			}
			cursor += 1
		}
		return (bytes.count, bytes.count)
	}

	func lowercased(_ byte: UInt8) -> UInt8 {
		byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") ? byte + 32 : byte
	}
}
