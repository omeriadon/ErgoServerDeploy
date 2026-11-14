//
//  BoardSharing+Members.swift
//  Ergo
//
//  Created by Adon Omeri on 8/11/2026.
//

import ErgoProtocol
import Fluent
import Foundation
import Logging

extension BoardSharing {
	// MARK: - Members

	/// Takes effect on their next push, which is checked against this
	func updateMember(
		board: String?,
		member: String?,
		role: BoardRole,
		account: UUID,
		token: UUID?,
		on database: any Database,
		logger: Logger,
		now: Date = .now
	) async throws {
		let boardID = try Self.boardID(board)
		let key = boardID.uuidString
		let memberID = try Self.memberID(member)
		try Self.check(role: role)

		try await change(board: boardID, caller: account, token: token, on: database, logger: logger, now: now) { ledger, database in
			let board = try await Self.owned(key, by: account, ledger: &ledger, on: database)
			let target = try Self.other(memberID, on: board)
			guard target.boardRole != role else { return }

			target.role = role.rawValue
			try await target.save(on: database)
			try await ledger.writeShares(of: board, on: database)
			ledger.tell([target.$account.id], about: board, heading: role.canEdit ? "You can now edit" : "You can now only view")
		}
		logger.verbose("Changed a member's role", metadata: ["role": "\(role.rawValue)"])
	}

	/// Their rows stay, under a tombstone on the board, so pruning stays the only thing that deletes them
	func removeMember(board: String?, member: String?, account: UUID, token: UUID?, on database: any Database, logger: Logger, now: Date = .now) async throws {
		let boardID = try Self.boardID(board)
		let key = boardID.uuidString
		let memberID = try Self.memberID(member)

		try await change(board: boardID, caller: account, token: token, on: database, logger: logger, now: now) { ledger, database in
			let board = try await Self.owned(key, by: account, ledger: &ledger, on: database)
			let target = try Self.other(memberID, on: board)
			try await ledger.remove(target, from: key, tombstoningBoard: true, on: database)
			ledger.tell([target.$account.id], about: board, heading: "You were removed")
		}
		logger.verbose("Removed a member")
	}

	/// Everyone else loses the board, the owner keeps it as an ordinary private one
	func stopSharing(board: String?, account: UUID, token: UUID?, on database: any Database, logger: Logger, now: Date = .now) async throws {
		let boardID = try Self.boardID(board)
		let key = boardID.uuidString

		try await change(board: boardID, caller: account, token: token, on: database, logger: logger, now: now) { ledger, database in
			let board = try await Self.owned(key, by: account, ledger: &ledger, on: database)
			try await ledger.end(board, heading: "You were removed", deletingOwnersBoard: false, on: database)
		}
		logger.verbose("Stopped sharing a board")
	}

	// MARK: - Checks

	static func owned(_ key: String, by account: UUID, ledger: inout BoardLedger, on database: any Database) async throws -> SharedBoard {
		guard let board = try await ledger.shared(key, on: database) else {
			throw ServiceError(code: .invalidRequest, message: "Expected a shared board, found one that isn't shared")
		}
		guard board.share.$owner.id == account else {
			throw ServiceError.notBoardOwner
		}
		return board
	}

	/// A member the owner can do something to, so never the owner
	static func other(_ id: UUID, on board: SharedBoard) throws -> BoardMemberRow {
		guard let member = board.members.first(where: { $0.id == id }) else {
			throw ServiceError(code: .invalidRequest, message: "Expected a member of this board, found none with that id")
		}
		guard member.boardRole != .owner else {
			throw ServiceError(code: .invalidRequest, message: "Expected another member, the owner can't change or remove themselves")
		}
		return member
	}

	static func boardID(_ text: String?) throws -> UUID {
		guard let text, let id = UUID(uuidString: text), id.uuidString == text else {
			throw ServiceError(code: .invalidRequest, message: "Expected a board id to be an uppercase UUID")
		}
		return id
	}

	static func memberID(_ text: String?) throws -> UUID {
		guard let text, let id = UUID(uuidString: text) else {
			throw ServiceError(code: .invalidRequest, message: "Expected a member id to be a UUID")
		}
		return id
	}

	static func check(role: BoardRole) throws {
		guard role != .owner else {
			throw ServiceError(code: .invalidRequest, message: "Expected the role 'editor' or 'viewer', found 'owner'")
		}
	}

	static func checked(name: String) throws -> String {
		let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
		guard (1 ... nameCharacters).contains(trimmed.count) else {
			throw ServiceError(code: .invalidRequest, message: "Expected a name of 1 to \(nameCharacters) characters, found \(trimmed.count)")
		}
		return trimmed
	}
}
