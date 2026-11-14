//
//  SyncKind.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import Foundation

/// What a record is. A string rather than an enum, so an older app can still decode a kind added later and ignore it.
public struct SyncKind: RawRepresentable, Codable, Sendable, Hashable, Comparable, ExpressibleByStringLiteral {
	public let rawValue: String

	public init(rawValue: String) {
		self.rawValue = rawValue
	}

	public init(stringLiteral value: String) {
		rawValue = value
	}

	public init(from decoder: Decoder) throws {
		rawValue = try decoder.singleValueContainer().decode(String.self)
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		try container.encode(rawValue)
	}

	public static func < (a: SyncKind, b: SyncKind) -> Bool {
		a.rawValue < b.rawValue
	}

	/// id: the board's `UUID.uuidString`, uppercase
	public static let board: SyncKind = "board"

	/// id: `CatalogReference.id`
	public static let bookmark: SyncKind = "bookmark"

	/// id: a `SyncedSetting` raw value
	public static let setting: SyncKind = "setting"

	/// id: the statement's `UUID.uuidString`, uppercase. One claim on a board's canvas.
	public static let statement: SyncKind = "statement"

	/// id: the link's `UUID.uuidString`, uppercase. An arrow from a premise statement to a conclusion statement.
	public static let link: SyncKind = "link"

	/// id: the scratchpad's `UUID.uuidString`, uppercase. A saved argument on the Logic tab, with no children.
	public static let scratchpad: SyncKind = "scratchpad"

	/// id: the source's `UUID.uuidString`, uppercase. A block of text or a web link on a board's canvas.
	public static let source: SyncKind = "source"

	/// id: the board's `UUID.uuidString`, uppercase. Who's on a shared board, as this account sees it. Only the server
	/// writes it, so it isn't in `known`, which is what a device may push.
	public static let share: SyncKind = "share"

	/// id: the annotation's own `UUID.uuidString`, uppercase. One report of a board analysis. Only the server writes it.
	public static let annotation: SyncKind = "annotation"

	/// id: the board's `UUID.uuidString`, uppercase. How the board's latest analysis went. Only the server writes it.
	public static let analysis: SyncKind = "analysis"

	public static let known: [SyncKind] = [.board, .bookmark, .setting, .statement, .link, .scratchpad, .source]
}

// MARK: - Checks

public extension SyncKind {
	/// Only the server writes these, so a replica never pushes one
	var isServerOwned: Bool {
		self == .share || self == .annotation || self == .analysis
	}

	/// The field names a record of this kind may have. Empty for a kind this version doesn't know.
	var fieldNames: Set<String> {
		switch self {
			case .board:
				[SyncFieldName.created, SyncFieldName.name, SyncFieldName.deleted]
			case .scratchpad:
				Set([SyncFieldName.created, SyncFieldName.name, SyncFieldName.content, SyncFieldName.deleted]
					+ (0 ..< SyncFieldName.descriptorSlots).map(SyncFieldName.descriptor))
			case .statement:
				[SyncFieldName.board, SyncFieldName.position, SyncFieldName.content, SyncFieldName.source, SyncFieldName.deleted]
			case .source:
				[SyncFieldName.board, SyncFieldName.position, SyncFieldName.content, SyncFieldName.deleted]
			case .link:
				[SyncFieldName.board, SyncFieldName.premise, SyncFieldName.conclusion, SyncFieldName.deleted]
			case .bookmark:
				[SyncFieldName.present]
			case .setting:
				[SyncFieldName.value]
			case .share:
				[SyncFieldName.role, SyncFieldName.member, SyncFieldName.members, SyncFieldName.deleted]
			case .annotation, .analysis:
				[SyncFieldName.board, SyncFieldName.content, SyncFieldName.deleted]
			default:
				[]
		}
	}

	/// Whether `id` can name a record of this kind
	func isValid(id: String) -> Bool {
		switch self {
			case .board, .statement, .link, .scratchpad, .source, .share, .annotation, .analysis:
				UUID(uuidString: id)?.uuidString == id
			case .bookmark:
				!id.isEmpty && id.utf8.count <= 256
			case .setting:
				SyncedSetting(rawValue: id) != nil
			default:
				false
		}
	}
}
