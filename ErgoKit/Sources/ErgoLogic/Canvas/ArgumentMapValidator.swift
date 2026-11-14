//
//  ArgumentMapValidator.swift
//  ErgoKit
//
//  Created by Adon Omeri on 6/11/2026.
//

import Foundation

public enum ArgumentMapProblem: Equatable, Sendable, Error {
	case tooManyStatements(limit: Int, found: Int)
	case duplicateStatement(UUID)
	case duplicateLinkID(UUID)

	/// An end of the link is a statement that isn't there
	case danglingLink(link: UUID, missing: UUID)

	/// The same premise and conclusion as an earlier link
	case duplicateLink(link: UUID, original: UUID)
	case selfLink(link: UUID, statement: UUID)

	/// Statements that arrow back round to where they started, in arrow order
	case cycle([UUID])

	public var message: String {
		switch self {
			case let .tooManyStatements(limit, found):
				"Expected at most \(limit) statements, found \(found)"
			case .duplicateStatement:
				"Expected every statement to have its own id, found a repeated one"
			case .duplicateLinkID:
				"Expected every link to have its own id, found a repeated one"
			case .danglingLink:
				"Expected a link between two statements, found a link to a statement that does not exist"
			case .duplicateLink:
				"Expected one link between two statements, found a second"
			case .selfLink:
				"Expected a link between two different statements, found a link from a statement to itself"
			case let .cycle(ids):
				"Expected arrows that never loop back, found a cycle through \(ids.count) statement\(ids.count == 1 ? "" : "s")"
		}
	}
}

public enum ArgumentMapValidator {
	/// The cap suggested in the plan; it is enforced when adding, and again here for maps from outside
	public static let defaultMaximumStatements = 60

	/// Everything wrong with the map, empty when it is fine. A bad link is reported once and left out of the cycle search.
	public static func validate(
		_ map: ArgumentMap<some Any, some Any>,
		maximumStatements: Int = defaultMaximumStatements
	) -> [ArgumentMapProblem] {
		var problems: [ArgumentMapProblem] = []

		if map.statements.count > maximumStatements {
			problems.append(.tooManyStatements(limit: maximumStatements, found: map.statements.count))
		}

		var ids: Set<UUID> = []
		for statement in map.statements where !ids.insert(statement.id).inserted {
			problems.append(.duplicateStatement(statement.id))
		}

		var linkIDs: Set<UUID> = []
		var pairs: [Pair: UUID] = [:]
		var good: [(premise: UUID, conclusion: UUID)] = []

		for link in map.links {
			guard linkIDs.insert(link.id).inserted else {
				problems.append(.duplicateLinkID(link.id))
				continue
			}
			if let missing = [link.premise, link.conclusion].first(where: { !ids.contains($0) }) {
				problems.append(.danglingLink(link: link.id, missing: missing))
			} else if link.premise == link.conclusion {
				problems.append(.selfLink(link: link.id, statement: link.premise))
			} else if let original = pairs[Pair(link.premise, link.conclusion)] {
				problems.append(.duplicateLink(link: link.id, original: original))
			} else {
				pairs[Pair(link.premise, link.conclusion)] = link.id
				good.append((link.premise, link.conclusion))
			}
		}

		if let cycle = cycle(among: map.statements.map(\.id), links: good) {
			problems.append(.cycle(cycle))
		}

		return problems
	}

	/// What would be wrong if `link` were added, for refusing an arrow before it is drawn
	public static func problem<Link>(adding link: Link, to map: ArgumentMap<some Any, Link>) -> ArgumentMapProblem? {
		if map.links.contains(where: { $0.id == link.id }) {
			return .duplicateLinkID(link.id)
		}
		let ids = Set(map.statements.map(\.id))
		if let missing = [link.premise, link.conclusion].first(where: { !ids.contains($0) }) {
			return .danglingLink(link: link.id, missing: missing)
		}
		if link.premise == link.conclusion {
			return .selfLink(link: link.id, statement: link.premise)
		}
		if let original = map.links.first(where: { $0.premise == link.premise && $0.conclusion == link.conclusion }) {
			return .duplicateLink(link: link.id, original: original.id)
		}
		if map.reaches(link.conclusion, link.premise) {
			return .cycle([link.premise, link.conclusion])
		}
		return nil
	}

	// MARK: - Cycles

	private struct Pair: Hashable {
		let premise: UUID
		let conclusion: UUID

		init(_ premise: UUID, _ conclusion: UUID) {
			self.premise = premise
			self.conclusion = conclusion
		}
	}

	/// The first loop found, searching depth first from statements in listing order. Iterative, so a long chain can't overflow the stack.
	private static func cycle(among ids: [UUID], links: [(premise: UUID, conclusion: UUID)]) -> [UUID]? {
		var next: [UUID: [UUID]] = [:]
		for link in links {
			next[link.premise, default: []].append(link.conclusion)
		}

		var finished: Set<UUID> = []

		for start in ids where !finished.contains(start) {
			var path: [UUID] = [start]
			var onPath: Set<UUID> = [start]
			var cursor = [0]

			while let id = path.last {
				let children = next[id] ?? []
				let position = cursor[cursor.count - 1]

				guard position < children.count else {
					finished.insert(id)
					onPath.remove(id)
					path.removeLast()
					cursor.removeLast()
					continue
				}

				cursor[cursor.count - 1] += 1
				let child = children[position]

				if onPath.contains(child) {
					return Array(path[(path.firstIndex(of: child) ?? 0)...])
				}
				if !finished.contains(child) {
					path.append(child)
					onPath.insert(child)
					cursor.append(0)
				}
			}
		}

		return nil
	}
}
