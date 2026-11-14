//
//  BoardShare.swift
//  ErgoKit
//
//  Created by Adon Omeri on 7/11/2026.
//

import Foundation

/// What someone can do on a shared board
public enum BoardRole: String, Codable, Sendable, Hashable {
	case owner, editor, viewer

	/// A role added later reads as `viewer` in an older app: the least it could mean, and the server is the judge anyway
	public init(wire: String) {
		self = Self(rawValue: wire) ?? .viewer
	}

	public init(from decoder: any Decoder) throws {
		try self.init(wire: decoder.singleValueContainer().decode(String.self))
	}
}

public extension BoardRole {
	var canEdit: Bool {
		self != .viewer
	}
}

public struct BoardMember: Codable, Sendable, Hashable, Identifiable {
	public var id: UUID
	public var name: String
	public var role: BoardRole

	public init(id: UUID, name: String, role: BoardRole) {
		self.id = id
		self.name = name
		self.role = role
	}
}

/// A `share` record, read: who's on a board, as one account sees it
public struct BoardShare: Sendable, Hashable {
	/// The board's id, which is also the record's
	public var board: String

	/// What this account can do
	public var role: BoardRole

	/// This account's member id
	public var member: UUID

	/// Everyone on the board, owner included
	public var members: [BoardMember]

	public init(board: String, role: BoardRole, member: UUID, members: [BoardMember]) {
		self.board = board
		self.role = role
		self.member = member
		self.members = members
	}
}

// MARK: - Records

public extension BoardShare {
	/// Nil for another kind, a tombstone, or fields this version can't read
	init?(_ record: SyncRecord) {
		guard record.kind == .share, !record.isDeleted,
		      case let .string(role)? = record.fields[SyncFieldName.role]?.value,
		      case let .string(member)? = record.fields[SyncFieldName.member]?.value,
		      let member = UUID(uuidString: member),
		      let members = try? record.fields[SyncFieldName.members]?.value.decode([BoardMember].self)
		else {
			return nil
		}
		self.init(board: record.id, role: BoardRole(wire: role), member: member, members: members)
	}

	/// What the server writes. Built by hand rather than with an encoder, since these values can't fail to encode and
	/// have no dates, so they come out the same as the app's `SyncCoding`, which ErgoSync can't see.
	var fields: [String: JSONValue] {
		[
			SyncFieldName.role: .string(role.rawValue),
			SyncFieldName.member: .string(member.uuidString),
			SyncFieldName.members: .array(members.map { member in
				["id": .string(member.id.uuidString), "name": .string(member.name), "role": .string(member.role.rawValue)]
			}),
		]
	}
}
