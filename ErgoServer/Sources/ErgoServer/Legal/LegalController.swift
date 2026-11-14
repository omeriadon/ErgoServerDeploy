//
//  LegalController.swift
//  ErgoServer
//
//  Created by Adon Omeri on 11/11/2026.
//

import ErgoProtocol
import Foundation
import Vapor

/// The privacy policy and the terms as web pages, for the App Store listing, the app and the paywall to link to.
/// They're written as markdown beside this file, and turned into HTML once, when first asked for.
enum LegalController {
	enum Document: String, CaseIterable {
		case privacyPolicy = "privacy-policy"
		case terms

		var path: String {
			switch self {
				case .privacyPolicy: ErgoProtocol.Path.privacyPolicy
				case .terms: ErgoProtocol.Path.terms
			}
		}
	}

	/// What `ProtocolVersionMiddleware` lets through without the header, since browsers have never heard of it
	static func isPage(_ parts: [Substring]) -> Bool {
		parts.count == 1 && Document.allCases.contains { $0.path == parts[0] }
	}

	private static let pages: [Document: String] = Dictionary(uniqueKeysWithValues: Document.allCases.compactMap { document in
		Bundle.module.url(forResource: document.rawValue, withExtension: "md")
			.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
			.map { (document, html(markdown: $0)) }
	})

	/// Checked at launch, so a broken bundle is found before anyone follows a link
	static var missing: [String] {
		Document.allCases.filter { pages[$0] == nil }.map(\.rawValue)
	}

	static func page(_ document: Document) -> Response {
		guard let page = pages[document] else {
			return Response(status: .notFound)
		}
		var headers = HTTPHeaders()
		headers.contentType = .html
		headers.replaceOrAdd(name: "Cache-Control", value: "public, max-age=3600")
		return Response(status: .ok, headers: headers, body: .init(string: page))
	}

	// MARK: - Markdown

	/// Only what these two files use: `#` headings, `-` lists, paragraphs, `**bold**` and `[links](…)`.
	/// Everything else is shown as written.
	static func html(markdown: String) -> String {
		var title = "Ergo"
		var body: [String] = []
		var paragraph: [String] = []
		var items: [String] = []

		func flush() {
			if !paragraph.isEmpty {
				body.append("<p>\(inline(paragraph.joined(separator: " ")))</p>")
				paragraph = []
			}
			if !items.isEmpty {
				body.append("<ul>\n" + items.map { "<li>\(inline($0))</li>" }.joined(separator: "\n") + "\n</ul>")
				items = []
			}
		}

		for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
			let line = line.trimmingCharacters(in: .whitespaces)
			let hashes = line.prefix { $0 == "#" }.count
			if line.isEmpty {
				flush()
			} else if (1 ... 3).contains(hashes), line.dropFirst(hashes).hasPrefix(" ") {
				flush()
				let text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
				if hashes == 1 {
					title = text
				}
				body.append("<h\(hashes)>\(inline(text))</h\(hashes)>")
			} else if line.hasPrefix("- ") {
				if !paragraph.isEmpty {
					flush()
				}
				items.append(String(line.dropFirst(2)))
			} else {
				if !items.isEmpty {
					flush()
				}
				paragraph.append(line)
			}
		}
		flush()

		return """
		<!doctype html>
		<html lang="en">
		<head>
		<meta charset="utf-8">
		<meta name="viewport" content="width=device-width, initial-scale=1">
		<title>\(escaped(title))</title>
		<style>
		:root { color-scheme: light dark; }
		body { font: 17px/1.55 -apple-system, system-ui, sans-serif; max-width: 40em; margin: 0 auto; padding: 32px 24px 64px; }
		h1 { font-size: 1.8em; line-height: 1.2; }
		h2 { font-size: 1.3em; margin-top: 2em; }
		h3 { font-size: 1.05em; margin-top: 1.6em; }
		li { margin: 0.4em 0; }
		</style>
		</head>
		<body>
		\(body.joined(separator: "\n"))
		</body>
		</html>
		"""
	}

	/// Escapes the text, then puts back bold and links. A link only goes to `https://`, or to another page here.
	static func inline(_ text: String) -> String {
		var rest = Substring(escaped(text))
		var result = ""

		// Links
		while let open = rest.firstIndex(of: "[") {
			let afterOpen = rest[rest.index(after: open)...]
			guard
				let middle = afterOpen.range(of: "]("),
				let close = afterOpen[middle.upperBound...].firstIndex(of: ")")
			else {
				break
			}
			let label = afterOpen[..<middle.lowerBound]
			let target = afterOpen[middle.upperBound ..< close]
			result += rest[..<open]
			if !label.contains("["), target.hasPrefix("https://") || target.hasPrefix("/") {
				result += "<a href=\"\(target)\">\(label)</a>"
				rest = rest[rest.index(after: close)...]
			} else {
				// Not a link, so only the bracket is passed over: a real one may follow
				result += "["
				rest = afterOpen
			}
		}
		result += rest

		// Bold: every second piece between `**` marks, when the marks pair up
		let pieces = result.components(separatedBy: "**")
		guard pieces.count > 1, pieces.count % 2 == 1 else { return result }
		return pieces.enumerated().map { $0.offset % 2 == 1 ? "<strong>\($0.element)</strong>" : $0.element }.joined()
	}

	private static func escaped(_ text: String) -> String {
		text
			.replacingOccurrences(of: "&", with: "&amp;")
			.replacingOccurrences(of: "<", with: "&lt;")
			.replacingOccurrences(of: ">", with: "&gt;")
			.replacingOccurrences(of: "\"", with: "&quot;")
			.replacingOccurrences(of: "'", with: "&#39;")
	}
}
