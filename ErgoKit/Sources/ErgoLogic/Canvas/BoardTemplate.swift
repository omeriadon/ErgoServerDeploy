//
//  BoardTemplate.swift
//  ErgoKit
//
//  Created by Adon Omeri on 14/11/2026.
//

import Foundation

/// A shape a new board can start from: a few cards, laid out and linked, each saying what goes in it.
///
/// The only link is "premise of", so every arrow here reads as "this card is a reason for that one". A card that argues
/// against another (an objection, a rebuttal) is never linked to it, and sits apart.
public enum BoardTemplate: String, CaseIterable, Identifiable, Sendable {
	/// Today's new board: one empty card
	case blank
	case claimAndReasons
	case objectionAndReply
	case prosAndCons

	/// Toulmin's model, as far as "premise of" goes: grounds and warrant support the claim, backing supports the warrant.
	/// The qualifier is part of the claim, and the rebuttal stands apart.
	case toulmin

	public var id: Self {
		self
	}

	public var title: String {
		switch self {
			case .blank: "Blank"
			case .claimAndReasons: "Claim and Reasons"
			case .objectionAndReply: "Objection and Reply"
			case .prosAndCons: "Pros and Cons"
			case .toulmin: "Toulmin"
		}
	}

	/// What goes in each card, in the order the layout reads them
	public var cards: [String] {
		switch self {
			case .blank:
				[]
			case .claimAndReasons:
				[
					"The claim you're testing",
					"A reason for it",
					"Another reason for it",
					"A third reason for it",
				]
			case .objectionAndReply:
				[
					"The claim you're defending",
					"A reason for it",
					"A reply: why the objection fails",
					"An objection to the claim",
				]
			case .prosAndCons:
				[
					"One answer to the question",
					"A point in its favour",
					"Another point in its favour",
					"The opposing answer",
					"A point in its favour",
					"Another point in its favour",
				]
			case .toulmin:
				[
					"The claim, and how sure you are of it",
					"The grounds: the evidence for the claim",
					"The warrant: why the grounds support it",
					"The backing: what supports the warrant",
					"The rebuttal: when the claim wouldn't hold",
				]
		}
	}

	/// Premise to conclusion, as indices into `cards`
	public var links: [(premise: Int, conclusion: Int)] {
		switch self {
			case .blank:
				[]
			case .claimAndReasons:
				[(1, 0), (2, 0), (3, 0)]
			case .objectionAndReply:
				[(1, 0), (2, 0)]
			case .prosAndCons:
				[(1, 0), (2, 0), (4, 3), (5, 3)]
			case .toulmin:
				[(1, 0), (2, 0), (3, 2)]
		}
	}

	/// Replaces what's in `map` with the template's cards, laid out (`CanvasLayout.arranged`) and linked, every card's
	/// English empty. Gives back what goes in each card, by id, since a generic statement can't hold it. Blank leaves the
	/// map as it is, as a board always has a card.
	@discardableResult
	public func apply<Node, Link>(to map: inout ArgumentMap<Node, Link>, makeID: () -> UUID = { UUID() }) -> [UUID: String] {
		guard !cards.isEmpty else { return [:] }

		let statements = cards.map { _ in Node(id: makeID(), position: .zero, english: "") }
		let links = links.map { Link(id: makeID(), premise: statements[$0.premise].id, conclusion: statements[$0.conclusion].id) }
		map = CanvasLayout.arranged(ArgumentMap(statements: statements, links: links))

		var placeholders: [UUID: String] = [:]
		for (statement, card) in zip(statements, cards) {
			placeholders[statement.id] = card
		}
		return placeholders
	}
}
