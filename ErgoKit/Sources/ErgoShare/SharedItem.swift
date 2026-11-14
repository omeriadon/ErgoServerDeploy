//
//  SharedItem.swift
//  ErgoKit
//
//  Created by Adon Omeri on 7/11/2026.
//

import Foundation

/// What came in through the share sheet, and what the person chose to do with it
public struct SharedItem: Codable, Hashable, Sendable {
	public enum Content: Codable, Hashable, Sendable {
		case text(String)
		case link(URL, title: String?)
	}

	public enum Action: String, Codable, Hashable, Sendable {
		case ask
		case breakDown
		case board
	}

	/// More than anyone would read through in a chat box, and far under what `AskRequest` allows
	public static let textLimit = 20000

	public var content: Content
	public var action: Action

	public init(content: Content, action: Action) {
		self.content = content
		self.action = action
	}
}

public extension SharedItem.Content {
	/// Longer text beside a link is what the person selected, not the page's title
	private static let titleLimit = 300

	/// Apps share a link, some text, or both. Nil when there's nothing usable, like a file's URL.
	init?(url: URL?, text: String?) {
		let text = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

		if let url, url.isWebLink {
			if text.count > Self.titleLimit {
				self = .text(SharedText.cut(text, to: SharedItem.textLimit))
			} else {
				self = .link(url, title: text.isEmpty || URL(string: text)?.isWebLink == true ? nil : text)
			}
			return
		}

		guard !text.isEmpty else { return nil }

		if let link = URL(string: text), link.isWebLink {
			self = .link(link, title: nil)
		} else {
			self = .text(SharedText.cut(text, to: SharedItem.textLimit))
		}
	}
}

public extension URL {
	var isWebLink: Bool {
		guard let scheme = scheme?.lowercased(), let host, !host.isEmpty else { return false }
		return scheme == "https" || scheme == "http"
	}
}

public enum SharedText {
	/// At most `limit` characters, ending on a sentence when one ends in the second half of them, else on a word
	public static func cut(_ text: String, to limit: Int) -> String {
		guard text.count > limit else { return text }
		let kept = text.prefix(limit)
		let secondHalf = kept.dropFirst(limit / 2)

		if let end = secondHalf.lastIndex(where: { ".!?\n".contains($0) }) {
			return kept[...end].trimmingCharacters(in: .whitespacesAndNewlines)
		}
		if let space = secondHalf.lastIndex(where: \.isWhitespace) {
			return kept[..<space].trimmingCharacters(in: .whitespacesAndNewlines)
		}
		return String(kept)
	}
}
