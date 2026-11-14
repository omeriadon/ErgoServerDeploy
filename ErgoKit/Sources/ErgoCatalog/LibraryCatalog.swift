//
//  LibraryCatalog.swift
//  ErgoKit
//
//  Created by Adon Omeri on 6/11/2026.
//

import Foundation

/// Ergo's library as plain text, for what reads it without showing it: the server's tools for the model, and the
/// app's intents that share them. The app's Library has richer models of its own, from these same files.
public struct LibraryCatalog: Sendable {
	public static let categories = ["biases", "concepts", "fallacies", "symbols", "paradoxes", "philosophers", "razors", "arguments"]

	/// Loaded the first time it's needed. Nil only if the package's resources are broken.
	public static let shared = try? LibraryCatalog.load()

	/// Every entry as `category/id`, read without building the entries' search text, so checking that one exists stays cheap.
	/// Empty only if the package's resources are broken.
	public static let entryIDs: Set<String> = {
		struct Item: Decodable {
			let id: String
		}
		var ids: Set<String> = []
		for category in categories {
			guard
				let url = url(of: category),
				let data = try? Data(contentsOf: url),
				let file = try? JSONDecoder().decode([String: [Item]].self, from: data),
				let items = file[category]
			else {
				continue
			}
			ids.formUnion(items.map { "\(category)/\($0.id)" })
		}
		return ids
	}()

	public let entries: [LibraryEntryText]

	public init(entries: [LibraryEntryText]) {
		self.entries = entries
	}

	/// One of the JSON files, for `CatalogStore`, so the app and the server read the same library
	public static func url(of name: String) -> URL? {
		Bundle.module.url(forResource: name, withExtension: "json")
	}

	public static func load() throws -> LibraryCatalog {
		var entries: [LibraryEntryText] = []
		for category in categories {
			guard let url = url(of: category) else {
				throw CocoaError(.fileNoSuchFile)
			}
			entries += try LibraryEntryText.entries(in: Data(contentsOf: url), category: category)
		}
		return LibraryCatalog(entries: entries)
	}

	public func entry(category: String, id: String) -> LibraryEntryText? {
		entries.first { $0.category == category && $0.id == id }
	}

	/// The most words of a query that count. Every one is looked for in every entry, and a model can send any amount.
	public static let queryWordLimit = 16

	/// Best first. Every word of the query counts once, up to `queryWordLimit`, and a match in the name counts most.
	public func search(_ query: String, category: String? = nil, limit: Int = 12) -> [LibraryEntryText] {
		var words: [String] = []
		for word in LibraryEntryText.words(in: query) where words.count < Self.queryWordLimit && !words.contains(word) {
			words.append(word)
		}
		guard !words.isEmpty else { return [] }
		let phrase = words.joined(separator: " ")

		return entries.lazy
			.filter { category == nil || $0.category == category }
			.map { ($0, $0.score(words: words, phrase: phrase)) }
			.filter { $0.1 > 0 }
			.sorted { ($0.1, $1.0.name) > ($1.1, $0.0.name) }
			.prefix(limit)
			.map(\.0)
	}

	/// By name, optionally only those with a tag
	public func list(category: String, tag: String? = nil, limit: Int = 60) -> [LibraryEntryText] {
		let tag = tag?.lowercased()
		return entries
			.filter { $0.category == category && (tag == nil || $0.tags.contains { $0.lowercased() == tag }) }
			.sorted { $0.name < $1.name }
			.prefix(limit)
			.map(\.self)
	}
}

/// One entry of the library, whichever kind it is
public struct LibraryEntryText: Sendable, Hashable, Identifiable {
	public let category: String
	public let id: String
	public let name: String
	public let aliases: [String]
	public let summary: String
	public let tags: [String]

	/// Everything the entry says, as JSON, minus what only the app's screens use
	public let details: String

	private let searchableName: String
	private let searchableAliases: String
	private let searchableTags: String
	private let searchableSummary: String

	public init(category: String, id: String, name: String, aliases: [String], summary: String, tags: [String], details: String) {
		self.category = category
		self.id = id
		self.name = name
		self.aliases = aliases
		self.summary = summary
		self.tags = tags
		self.details = details
		searchableName = Self.words(in: name).joined(separator: " ")
		searchableAliases = Self.words(in: aliases.joined(separator: " ")).joined(separator: " ")
		searchableTags = Self.words(in: tags.joined(separator: " ")).joined(separator: " ")
		searchableSummary = Self.words(in: summary).joined(separator: " ")
	}

	private static let screenOnlyKeys: Set<String> = ["image", "symbolName"]

	static func entries(in data: Data, category: String) throws -> [LibraryEntryText] {
		guard
			let file = try JSONSerialization.jsonObject(with: data) as? [String: Any],
			let items = file[category] as? [[String: Any]]
		else {
			throw CocoaError(.fileReadCorruptFile)
		}

		return try items.compactMap { item in
			guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
			let details = try JSONSerialization.data(
				withJSONObject: item.filter { !screenOnlyKeys.contains($0.key) },
				options: [.sortedKeys, .withoutEscapingSlashes]
			)
			return LibraryEntryText(
				category: category,
				id: id,
				name: name,
				aliases: item["aliases"] as? [String] ?? [],
				summary: item["summary"] as? String ?? "",
				tags: item["tags"] as? [String] ?? [],
				details: String(decoding: details, as: UTF8.self)
			)
		}
	}

	static func words(in text: String) -> [String] {
		text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
	}

	func score(words: [String], phrase: String) -> Double {
		var score = 0.0
		if searchableName == phrase {
			score += 100
		} else if searchableName.contains(phrase) {
			score += 40
		}
		if searchableAliases.contains(phrase) {
			score += 30
		}
		for word in words {
			if searchableName.contains(word) {
				score += 8
			}
			if searchableAliases.contains(word) {
				score += 6
			}
			if searchableTags.contains(word) {
				score += 3
			}
			if searchableSummary.contains(word) {
				score += 2
			}
		}
		return score
	}
}
