//
//  ArgumentBreakdownApply.swift
//  ErgoKit
//
//  Created by Adon Omeri on 6/11/2026.
//

import ErgoLogic
import Foundation

/// The map after a breakdown went into it, and what didn't fit
public struct ArgumentBreakdownApplication<Node: ArgumentNode, Link: ArgumentLink>: Sendable {
	public var map: ArgumentMap<Node, Link>

	/// New statements, premises in order and then the conclusion
	public var added: [UUID]

	/// The new statement for the conclusion, nil when the text drew none or it didn't fit
	public var conclusion: UUID?

	/// Premises left out because the board was full
	public var skippedPremises: Int

	/// The conclusion was left out because the board was full
	public var skippedConclusion: Bool

	/// How many statements didn't fit
	public var skipped: Int {
		skippedPremises + (skippedConclusion ? 1 : 0)
	}
}

public extension ArgumentBreakdown {
	/// The map with this breakdown in it: a statement per premise and one for the conclusion, every premise linked to it.
	///
	/// - Adding keeps every statement where it is. The new ones are laid out as a block under the existing content,
	///   left edges lined up, so nothing overlaps and nothing moves.
	/// - Replacing starts from an empty map, and the whole result is laid out. A breakdown with nothing in it leaves the map as it was.
	/// - Statements past `maximumStatements` are left out, premises last: one place is kept for the conclusion.
	///
	/// The English of each statement is the quote as returned, trimmed. Blank quotes are skipped.
	func applied<Node, Link>(
		to map: ArgumentMap<Node, Link>,
		replacing: Bool,
		maximumStatements: Int = ArgumentMapValidator.defaultMaximumStatements,
		makeID: () -> UUID = { UUID() }
	) -> ArgumentBreakdownApplication<Node, Link> {
		let premises = premises.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
		let conclusion = conclusion.trimmingCharacters(in: .whitespacesAndNewlines)
		let hasConclusion = !conclusion.isEmpty

		var result = ArgumentBreakdownApplication(map: map, added: [], conclusion: nil, skippedPremises: 0, skippedConclusion: false)
		guard !premises.isEmpty || hasConclusion else { return result }

		var base = replacing ? ArgumentMap<Node, Link>() : map
		let room = max(maximumStatements - base.statements.count, 0)
		let conclusionFits = hasConclusion && room > 0
		let premiseRoom = room - (conclusionFits ? 1 : 0)
		let kept = premises.prefix(premiseRoom)
		result.skippedPremises = premises.count - kept.count
		result.skippedConclusion = hasConclusion && !conclusionFits
		guard !kept.isEmpty || conclusionFits else {
			// Nothing fits, and replacing must not empty the board for nothing
			return result
		}

		var block = ArgumentMap<Node, Link>()
		for quote in kept {
			block.statements.append(Node(id: makeID(), position: .zero, english: quote))
		}
		if conclusionFits {
			let node = Node(id: makeID(), position: .zero, english: conclusion)
			block.statements.append(node)
			result.conclusion = node.id
			for premise in block.statements.dropLast() {
				block.links.append(Link(id: makeID(), premise: premise.id, conclusion: node.id))
			}
		}

		// Laid out on its own, then moved under what's there
		block = CanvasLayout.arranged(block)
		if !base.statements.isEmpty {
			let boxes = base.statements.map { CanvasRect(center: $0.position, size: CanvasLayout.boxSize) }
			let left = boxes.map(\.minX).min() ?? 0
			let bottom = boxes.map(\.maxY).max() ?? 0
			let offset = CanvasPoint(x: left, y: bottom + CanvasLayout.rowGap * 2)
			for index in block.statements.indices {
				block.statements[index].position = block.statements[index].position + offset
			}
		}

		// Links go through the validator, so a refused one is dropped rather than breaking the map
		base.statements += block.statements
		for link in block.links where ArgumentMapValidator.problem(adding: link, to: base) == nil {
			base.links.append(link)
		}

		result.map = base
		result.added = block.statements.map(\.id)
		return result
	}
}
