//
//  ArgumentMap.swift
//  ErgoKit
//
//  Created by Adon Omeri on 6/11/2026.
//

import Foundation

/// Statements and the arrows between them. Nothing is stored about conclusions: a statement with incoming
/// links is the conclusion of those premises, and one with no outgoing links is a final conclusion.
///
/// The queries trust the links and ignore self-links. Run `ArgumentMapValidator` first when the map came from outside.
public struct ArgumentMap<Node: ArgumentNode, Link: ArgumentLink>: Sendable {
	public var statements: [Node]
	public var links: [Link]

	public init(statements: [Node] = [], links: [Link] = []) {
		self.statements = statements
		self.links = links
	}

	/// Which statement goes first when the order leaves a choice
	public enum TieBreak: Sendable {
		/// Top to bottom, then left to right, so what you read on the canvas is what comes first
		case position

		/// The order of `statements`, so the result doesn't change when boxes are dragged
		case listing
	}

	public func statement(_ id: UUID) -> Node? {
		statements.first { $0.id == id }
	}

	// MARK: - Queries

	/// In link order, each once
	public func premises(of id: UUID) -> [UUID] {
		unique(links.lazy.filter { $0.conclusion == id && $0.premise != id }.map(\.premise))
	}

	public func conclusions(of id: UUID) -> [UUID] {
		unique(links.lazy.filter { $0.premise == id && $0.conclusion != id }.map(\.conclusion))
	}

	/// Has incoming links, so the checker has an argument to look at
	public func isConclusion(_ id: UUID) -> Bool {
		links.contains { $0.conclusion == id && $0.premise != id }
	}

	/// Has incoming links and nothing it feeds into: the end of an argument
	public func isFinalConclusion(_ id: UUID) -> Bool {
		isConclusion(id) && !links.contains { $0.premise == id && $0.conclusion != id }
	}

	/// Statements nothing points at, in listing order. Unlinked statements count.
	public var roots: [UUID] {
		let targets = Set(links.lazy.filter { $0.premise != $0.conclusion }.map(\.conclusion))
		return unique(statements.lazy.map(\.id).filter { !targets.contains($0) })
	}

	public var finalConclusions: [UUID] {
		unique(statements.lazy.map(\.id).filter(isFinalConclusion))
	}

	/// Whether following arrows from `start` gets to `target`. A statement doesn't reach itself without a loop.
	public func reaches(_ start: UUID, _ target: UUID) -> Bool {
		var next: [UUID: [UUID]] = [:]
		for link in links {
			next[link.premise, default: []].append(link.conclusion)
		}

		var seen: Set<UUID> = []
		var pending = next[start] ?? []
		while let id = pending.popLast() {
			if id == target {
				return true
			}
			if seen.insert(id).inserted {
				pending += next[id] ?? []
			}
		}
		return false
	}

	// MARK: - Order

	/// Premises always come before their conclusion. Anything caught in a cycle comes last, so a broken map still gets an order.
	/// Links to statements that aren't there are ignored, and so is a repeated statement id after its first.
	public func topologicalOrder(tieBreak: TieBreak = .position) -> [UUID] {
		var seen: Set<UUID> = []
		let unique = statements.filter { seen.insert($0.id).inserted }

		let rank = ranks(of: unique, tieBreak: tieBreak)
		var idAtRank = [UUID](repeating: UUID(), count: unique.count)
		var rankOf: [UUID: Int] = [:]
		for (index, statement) in unique.enumerated() {
			idAtRank[rank[index]] = statement.id
			rankOf[statement.id] = rank[index]
		}

		var following = [[Int]](repeating: [], count: unique.count)
		var waiting = [Int](repeating: 0, count: unique.count)
		for link in links where link.premise != link.conclusion {
			guard let premise = rankOf[link.premise], let conclusion = rankOf[link.conclusion] else { continue }
			following[premise].append(conclusion)
			waiting[conclusion] += 1
		}

		// Largest rank first, so the next statement is always `popLast()`
		var ready: [Int] = []
		func insert(_ value: Int) {
			var low = 0
			var high = ready.count
			while low < high {
				let middle = (low + high) / 2
				if ready[middle] > value {
					low = middle + 1
				} else {
					high = middle
				}
			}
			ready.insert(value, at: low)
		}

		for value in waiting.indices where waiting[value] == 0 {
			insert(value)
		}

		var order: [Int] = []
		var emitted = Set<Int>()
		while let value = ready.popLast() {
			order.append(value)
			emitted.insert(value)
			for conclusion in following[value] {
				waiting[conclusion] -= 1
				if waiting[conclusion] == 0 {
					insert(conclusion)
				}
			}
		}

		order += unique.indices.filter { !emitted.contains($0) }
		return order.map { idAtRank[$0] }
	}

	private func ranks(of statements: [Node], tieBreak: TieBreak) -> [Int] {
		switch tieBreak {
			case .listing:
				return Array(statements.indices)
			case .position:
				let sorted = statements.indices.sorted { left, right in
					let a = statements[left].position
					let b = statements[right].position
					return (a.y, a.x, left) < (b.y, b.x, right)
				}
				var rank = [Int](repeating: 0, count: statements.count)
				for (place, index) in sorted.enumerated() {
					rank[index] = place
				}
				return rank
		}
	}

	private func unique(_ ids: some Sequence<UUID>) -> [UUID] {
		var seen: Set<UUID> = []
		return ids.filter { seen.insert($0).inserted }
	}
}

extension ArgumentMap: Equatable where Node: Equatable, Link: Equatable {}
