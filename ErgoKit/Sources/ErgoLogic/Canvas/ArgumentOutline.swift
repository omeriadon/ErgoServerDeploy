//
//  ArgumentOutline.swift
//  ErgoKit
//
//  Created by Adon Omeri on 14/11/2026.
//

import Foundation

/// A map as an indented list: each final conclusion with its premises under it, and theirs under them, then the statements
/// with no arrows at all. It's the board's outline view and its markdown export, so both read the same.
///
/// A premise that supports more than one conclusion is listed under each, but its own premises only the first time, so
/// there are never more rows than statements and links. A broken map still lists everything: statements caught in a cycle
/// have no final conclusion to hang from, so they start arguments of their own after the others.
public struct ArgumentOutline: Hashable, Sendable {
	public struct Row: Hashable, Sendable {
		public var statement: UUID

		/// 0 for the statement an argument ends in, 1 for its premises, and so on
		public var depth: Int

		/// Listed in full further up, so its premises aren't repeated here
		public var isRepeat: Bool

		public init(statement: UUID, depth: Int, isRepeat: Bool = false) {
			self.statement = statement
			self.depth = depth
			self.isRepeat = isRepeat
		}
	}

	/// One per argument, the conclusion first, and every premise straight after the row it supports
	public var arguments: [[Row]]

	/// Statements with no arrows in or out
	public var unlinked: [UUID]

	public init(arguments: [[Row]] = [], unlinked: [UUID] = []) {
		self.arguments = arguments
		self.unlinked = unlinked
	}

	/// Arguments and premises come in reading order (`tieBreak`), so the outline reads like the canvas.
	/// Links to statements that aren't there, and self-links, are ignored.
	public init<Node, Link>(_ map: ArgumentMap<Node, Link>, tieBreak: ArgumentMap<Node, Link>.TieBreak = .position) {
		let order = map.topologicalOrder(tieBreak: tieBreak)
		var rank: [UUID: Int] = [:]
		for (index, id) in order.enumerated() where rank[id] == nil {
			rank[id] = index
		}

		var premises: [UUID: [UUID]] = [:]
		var feedsOn: Set<UUID> = []
		var linked: Set<UUID> = []
		for link in map.links where link.premise != link.conclusion {
			guard rank[link.premise] != nil, rank[link.conclusion] != nil else { continue }
			if !(premises[link.conclusion]?.contains(link.premise) ?? false) {
				premises[link.conclusion, default: []].append(link.premise)
			}
			feedsOn.insert(link.premise)
			linked.insert(link.premise)
			linked.insert(link.conclusion)
		}
		for id in premises.keys {
			premises[id]?.sort { rank[$0, default: 0] < rank[$1, default: 0] }
		}

		var expanded: Set<UUID> = []

		// Depth first without recursion, so a long chain can't overflow the stack
		func argument(endingIn root: UUID) -> [Row] {
			var rows: [Row] = []
			var pending = [(id: root, depth: 0)]
			while let (id, depth) = pending.popLast() {
				let isRepeat = expanded.contains(id)
				rows.append(Row(statement: id, depth: depth, isRepeat: isRepeat))
				guard !isRepeat else { continue }
				expanded.insert(id)
				for premise in (premises[id] ?? []).reversed() {
					pending.append((premise, depth + 1))
				}
			}
			return rows
		}

		var arguments: [[Row]] = []
		for id in order where linked.contains(id) && !feedsOn.contains(id) {
			arguments.append(argument(endingIn: id))
		}

		// Only a cycle leaves anything linked unlisted. Starting from the end of the order starts nearest the loop.
		for id in order.reversed() where linked.contains(id) && !expanded.contains(id) {
			arguments.append(argument(endingIn: id))
		}

		self.arguments = arguments
		unlinked = order.filter { !linked.contains($0) }
	}
}

// MARK: - Markdown

/// A source as the markdown export lists it, with the cards that belong to it. ErgoLogic doesn't know about sources,
/// so the app hands them over like this.
public struct ArgumentOutlineSource: Hashable, Sendable {
	public var title: String
	public var link: URL?
	public var text: String?

	/// Statement ids, in the order to list them
	public var members: [UUID]

	public init(title: String, link: URL? = nil, text: String? = nil, members: [UUID] = []) {
		self.title = title
		self.link = link
		self.text = text
		self.members = members
	}
}

/// A board as a markdown document: its arguments as nested lists from `ArgumentOutline`, the statements in no argument,
/// and its sources with their cards.
public enum ArgumentOutlineMarkdown {
	public static let emptyStatement = "*Empty statement*"

	public static func text(
		title: String,
		map: ArgumentMap<some Any, some Any>,
		sources: [ArgumentOutlineSource] = []
	) -> String {
		let outline = ArgumentOutline(map)
		var english: [UUID: String] = [:]
		for statement in map.statements where english[statement.id] == nil {
			english[statement.id] = statement.english
		}
		func line(_ id: UUID) -> String {
			inline(english[id] ?? "") ?? emptyStatement
		}

		var parts = ["# " + (inline(title) ?? "Untitled")]

		if !outline.arguments.isEmpty {
			let arguments = outline.arguments.map { rows in
				rows.map { row in
					let indent = String(repeating: "  ", count: row.depth)
					let marker = row.depth == 0 ? "∴ " : ""
					let repeated = row.isRepeat ? " *(see above)*" : ""
					return indent + "- " + marker + line(row.statement) + repeated
				}
				.joined(separator: "\n")
			}
			parts.append("## Arguments\n\n" + arguments.joined(separator: "\n\n"))
		}

		if !outline.unlinked.isEmpty {
			parts.append("## Other statements\n\n" + outline.unlinked.map { "- " + line($0) }.joined(separator: "\n"))
		}

		let known = Set(english.keys)
		let listed = sources.map { source in
			var section = ["### " + (inline(source.title) ?? "Untitled source")]
			if let link = source.link {
				section.append("<\(link.absoluteString)>")
			}
			if let text = source.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
				section.append(quoted(text))
			}
			let members = source.members.filter(known.contains)
			if !members.isEmpty {
				section.append(members.map { "- " + line($0) }.joined(separator: "\n"))
			}
			return section.joined(separator: "\n\n")
		}
		if !listed.isEmpty {
			parts.append("## Sources\n\n" + listed.joined(separator: "\n\n"))
		}

		return parts.joined(separator: "\n\n") + "\n"
	}

	/// On one line, and not starting with something markdown would read as a heading, quote or list. Nil when there's nothing.
	static func inline(_ text: String) -> String? {
		let words = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
		guard let first = words.first else { return nil }
		return "#>-+*".contains(first) ? "\\" + words : words
	}

	static func quoted(_ text: String) -> String {
		text.split(separator: "\n", omittingEmptySubsequences: false)
			.map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? ">" : "> " + $0 }
			.joined(separator: "\n")
	}
}
