//
//  AskModes.swift
//  ErgoKit
//
//  Created by Adon Omeri on 10/11/2026.
//

import Foundation

/// How a chat behaves. The server adds each mode's instructions to Ask's own. An unknown one reads as `.normal`, so a
/// mode added later doesn't break an older app.
public enum AskMode: String, Codable, Sendable, CaseIterable, Hashable {
	case normal, debate, scout

	public init(from decoder: any Decoder) throws {
		self = try Self(rawValue: decoder.singleValueContainer().decode(String.self)) ?? .normal
	}
}

/// The model asking to change the chat's mode. The person accepts or turns it down.
public struct AskModeRequest: Codable, Sendable, Hashable {
	public let mode: AskMode

	/// One line for the person, like "Argue about free will"
	public let reason: String

	public init(mode: AskMode, reason: String) {
		self.mode = mode
		self.reason = reason
	}
}

/// The board a chat is about, as it is now. `canEdit` is false on a board this person can only view, and the model then
/// gets no tools for changing it.
public struct AskBoard: Codable, Sendable, Hashable {
	public let title: String
	public let canEdit: Bool
	public let statements: [BoardAnalysisRequest.Statement]
	public let links: [BoardAnalysisRequest.Link]
	public let sources: [BoardAnalysisRequest.Source]

	public init(title: String, canEdit: Bool, statements: [BoardAnalysisRequest.Statement], links: [BoardAnalysisRequest.Link], sources: [BoardAnalysisRequest.Source]) {
		self.title = title
		self.canEdit = canEdit
		self.statements = statements
		self.links = links
		self.sources = sources
	}

	var characters: Int {
		statements.reduce(0) { $0 + $1.english.count } + sources.reduce(0) { $0 + $1.title.count + $1.text.count }
	}
}

/// One change the model made to the board. It's made on the device, which is told each one as it happens. `id` is what
/// stops a replayed answer making the same change twice.
public struct AskBoardEdit: Codable, Sendable, Hashable, Identifiable {
	public enum Change: Codable, Sendable, Hashable {
		/// `near` is the card to put it beside
		case addCard(id: UUID, english: String, near: UUID?)
		case editCard(id: UUID, english: String)
		case deleteCard(id: UUID)
		case connect(premise: UUID, conclusion: UUID)
		case disconnect(premise: UUID, conclusion: UUID)
	}

	public let id: UUID
	public let change: Change

	public init(id: UUID = UUID(), change: Change) {
		self.id = id
		self.change = change
	}
}
