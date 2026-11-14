//
//  Sharing.swift
//  ErgoKit
//
//  Created by Adon Omeri on 7/11/2026.
//

import Foundation

// `BoardRole`, `BoardMember`, `BoardShare` and `RejectedChange` live in ErgoSync, since `SyncReplica` handles them.
// Re-exported by `Sync.swift`, so the wire protocol is all one import.

// MARK: - Paths

public extension ErgoProtocol.Path {
	/// POST `CreateBoardInvite` → `BoardInvite`, owner or first share. DELETE → 204 revokes every open link, owner.
	static func boardInvites(_ board: String) -> String {
		"v1/boards/\(board)/invites"
	}

	/// POST `UpdateBoardMember` → 204. DELETE → 204 removes them. Owner.
	static func boardMember(_ board: String, _ member: String) -> String {
		"v1/boards/\(board)/members/\(member)"
	}

	/// DELETE → 204 stops sharing: everyone else loses the board, the owner keeps it. Owner.
	static func boardShare(_ board: String) -> String {
		"v1/boards/\(board)/share"
	}

	/// POST `ReportBoard` → 204. Anyone on the board, the owner included, limited per account.
	static func boardReport(_ board: String) -> String {
		"v1/boards/\(board)/report"
	}

	/// POST `BoardInviteToken` → `BoardInvitePreview`, no auth, limited per address
	static let invitePreview = "v1/invites/preview"

	/// POST `AcceptBoardInvite` → `JoinedBoard`
	static let inviteAccept = "v1/invites/accept"

	/// PUT `PushDevice` → 204. DELETE → 204, this device's token only.
	static let pushDevice = "v1/push/device"

	/// GET, public, no version header. Apple's CDN fetches it, so it can't redirect.
	static let appleAppSiteAssociation = ".well-known/apple-app-site-association"

	/// GET `join/<token>`, public, no version header: a small page for someone without the app
	static let join = "join"

	/// GET, public, no version header: the privacy policy as a web page
	static let privacyPolicy = "policy"

	/// GET, public, no version header: the terms of use as a web page
	static let terms = "terms"
}

// MARK: - Invites

public struct CreateBoardInvite: Codable, Sendable, Hashable {
	/// `editor` or `viewer`
	public let role: BoardRole

	/// The board's title as the owner's device has it, at most 200 characters. The server doesn't otherwise know it,
	/// since records are sealed, and it's what previews and pushes show.
	public let title: String

	/// The owner's name on this board, 1–60 characters after trimming
	public let name: String

	public init(role: BoardRole, title: String, name: String) {
		self.role = role
		self.title = title
		self.name = name
	}
}

public struct BoardInvite: Codable, Sendable, Hashable {
	/// `https://<public host>/join/<token>`
	public let url: URL
	public let role: BoardRole
	public let expires: Date

	public init(url: URL, role: BoardRole, expires: Date) {
		self.url = url
		self.role = role
		self.expires = expires
	}
}

public struct UpdateBoardMember: Codable, Sendable, Hashable {
	/// `editor` or `viewer`
	public let role: BoardRole

	public init(role: BoardRole) {
		self.role = role
	}
}

public struct BoardInviteToken: Codable, Sendable, Hashable {
	public let token: String

	public init(token: String) {
		self.token = token
	}
}

/// What an invite shows before joining
public struct BoardInvitePreview: Codable, Sendable, Hashable {
	public let board: String
	public let title: String
	public let ownerName: String
	public let role: BoardRole
	public let memberCount: Int

	public init(board: String, title: String, ownerName: String, role: BoardRole, memberCount: Int) {
		self.board = board
		self.title = title
		self.ownerName = ownerName
		self.role = role
		self.memberCount = memberCount
	}
}

public struct AcceptBoardInvite: Codable, Sendable, Hashable {
	public let token: String

	/// The joiner's name on this board, 1–60 characters after trimming
	public let name: String

	public init(token: String, name: String) {
		self.token = token
		self.name = name
	}
}

/// Accepting twice, or as the owner, keeps the role you have and answers normally
public struct JoinedBoard: Codable, Sendable, Hashable {
	public let board: String
	public let role: BoardRole

	public init(board: String, role: BoardRole) {
		self.board = board
		self.role = role
	}
}

// MARK: - Reports

/// A member's report of a shared board, for whoever looks after the server to read
public struct ReportBoard: Codable, Sendable, Hashable {
	public static let reasonCharacters = 1000

	/// Why, 1–1,000 characters after trimming
	public let reason: String

	public init(reason: String) {
		self.reason = reason
	}

	/// Trimmed. Throws a `ServiceError` worded for the user.
	public static func normalized(_ reason: String) throws -> String {
		let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
		guard (1 ... reasonCharacters).contains(trimmed.count) else {
			throw ServiceError(code: .invalidRequest, message: "Expected a reason of 1 to \(reasonCharacters) characters, found \(trimmed.count)")
		}
		return trimmed
	}
}

// MARK: - Links

/// Reads the token out of an invite link
public enum BoardInviteLink {
	/// The token of `https://<any host>/join/<token>` or `ergo://join/<token>`, nil for anything else.
	/// Any host, so a debug build pointed at This Mac still opens links.
	public static func token(from url: URL) -> String? {
		// `pathComponents` starts with "/" and leaves out a trailing slash
		let path = url.pathComponents.dropFirst()
		let token: String? = switch url.scheme?.lowercased() {
			case "https":
				path.count == 2 && path.first == ErgoProtocol.Path.join ? path.last : nil
			case "ergo":
				url.host() == ErgoProtocol.Path.join && path.count == 1 ? path.first : nil
			default:
				nil
		}
		return token?.isEmpty == false ? token : nil
	}
}

// MARK: - Push

public struct PushDevice: Codable, Sendable, Hashable {
	/// The APNs device token, as hex
	public let token: String

	public init(token: String) {
		self.token = token
	}
}
