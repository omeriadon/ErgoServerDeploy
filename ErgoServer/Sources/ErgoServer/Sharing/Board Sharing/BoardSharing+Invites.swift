//
//  BoardSharing+Invites.swift
//  Ergo
//
//  Created by Adon Omeri on 8/11/2026.
//

import ErgoProtocol
import Fluent
import Foundation
import Logging

extension BoardSharing {
	// MARK: - Invites

	/// The first invite shares the board. Later ones refresh its title and the owner's name, so what previews and pushes
	/// show keeps up with what the owner's device last said.
	func createInvite(
		_ body: CreateBoardInvite,
		board: String?,
		account: UUID,
		token: UUID?,
		on database: any Database,
		logger: Logger,
		now: Date = .now
	) async throws -> BoardInvite {
		let boardID = try Self.boardID(board)
		let key = boardID.uuidString
		try Self.check(role: body.role)
		guard body.title.count <= Self.titleCharacters else {
			throw ServiceError(code: .invalidRequest, message: "Expected a title of at most \(Self.titleCharacters) characters, found \(body.title.count)")
		}
		let name = try Self.checked(name: body.name)
		let sealedTitle = try vault.seal(title: body.title, board: boardID)

		let secret = Account.makeToken()
		let expires = now + Self.inviteLifetime
		guard let url = URL(string: "\(publicURL)/\(ErgoProtocol.Path.join)/\(secret)") else {
			throw ServiceError.internalFailure
		}

		try await change(board: boardID, caller: account, token: token, on: database, logger: logger, now: now) { ledger, database in
			if let shared = try await ledger.shared(key, on: database) {
				guard shared.share.$owner.id == account else {
					throw ServiceError.notBoardOwner
				}
				shared.share.sealedTitle = sealedTitle
				try await shared.share.save(on: database)
				if let owner = shared.owner, owner.name != name {
					owner.name = name
					try await owner.save(on: database)
					try await ledger.writeShares(of: shared, on: database)
				}
			} else {
				guard let row = try await SyncRecordRow.find(SyncRecord.Key(kind: .board, id: key), for: account, on: database), row.tombstone == nil else {
					throw ServiceError(code: .invalidRequest, message: "Expected a synced board, sync and try again")
				}
				let share = BoardShareRow(board: boardID, owner: account, sealedTitle: sealedTitle, now: now)
				try await share.save(on: database)
				let owner = BoardMemberRow(board: boardID, account: account, role: .owner, name: name, now: now)
				try await owner.save(on: database)
				let shared = SharedBoard(key: key, share: share, members: [owner])
				ledger.adopt(shared)
				try await ledger.writeShares(of: shared, on: database)
			}

			// Expired ones go whenever a new one is made, then the oldest, so it's never over the limit
			try await BoardInviteRow.query(on: database).filter(\.$board.$id == boardID).filter(\.$expires <= now).delete()
			let open = try await BoardInviteRow.query(on: database).filter(\.$board.$id == boardID).sort(\.$created).all()
			let doomed = open.prefix(max(0, open.count - (Self.invitesPerBoard - 1))).compactMap(\.id)
			if !doomed.isEmpty {
				try await BoardInviteRow.query(on: database).filter(\.$id ~~ doomed).delete()
			}
			let invite = BoardInviteRow(board: boardID, tokenHash: Account.hash(secret), role: body.role, now: now, expires: expires)
			try await invite.save(on: database)
		}

		logger.verbose("Made a board invite", metadata: ["role": "\(body.role.rawValue)"])
		return BoardInvite(url: url, role: body.role, expires: expires)
	}

	func revokeInvites(board: String?, account: UUID, token: UUID?, on database: any Database, logger: Logger, now: Date = .now) async throws {
		let boardID = try Self.boardID(board)
		let key = boardID.uuidString
		try await change(board: boardID, caller: account, token: token, on: database, logger: logger, now: now) { ledger, database in
			_ = try await Self.owned(key, by: account, ledger: &ledger, on: database)
			try await BoardInviteRow.query(on: database).filter(\.$board.$id == boardID).delete()
		}
		logger.verbose("Revoked board invites")
	}

	// MARK: - Previews

	/// What an invite shows before joining, to anyone holding the link. Reads only.
	func preview(_ body: BoardInviteToken, on database: any Database, now: Date = .now) async throws -> BoardInvitePreview {
		let hash = Account.hash(body.token)
		guard let invite = try await BoardInviteRow.query(on: database).filter(\.$tokenHash == hash).first(), invite.expires > now,
		      let share = try await BoardShareRow.find(invite.$board.id, on: database)
		else {
			throw ServiceError.inviteClosed
		}
		let members = try await BoardMemberRow.query(on: database).filter(\.$board.$id == invite.$board.id).all()
		let board = SharedBoard(key: invite.$board.id.uuidString, share: share, members: members)
		return BoardInvitePreview(
			board: board.key,
			title: board.title(vault) ?? PushEvent.untitled,
			ownerName: board.owner?.name ?? "",
			role: invite.boardRole,
			memberCount: members.count
		)
	}

	// MARK: - Joining

	/// Copies the board in, and tells the owner. Accepting again, or as the owner, keeps the role you have.
	func accept(_ body: AcceptBoardInvite, account: UUID, token: UUID?, on database: any Database, logger: Logger, now: Date = .now) async throws -> JoinedBoard {
		let name = try Self.checked(name: body.name)
		let hash = Account.hash(body.token)
		guard let found = try await BoardInviteRow.query(on: database).filter(\.$tokenHash == hash).first() else {
			throw ServiceError.inviteClosed
		}
		let boardID = found.$board.id
		let key = boardID.uuidString

		let joined = try await change(board: boardID, caller: account, token: token, on: database, logger: logger, now: now) { ledger, database -> JoinedBoard in
			guard let invite = try await BoardInviteRow.query(on: database).filter(\.$tokenHash == hash).first(), invite.expires > now,
			      let board = try await ledger.shared(key, on: database),
			      let owner = board.owner
			else {
				throw ServiceError.inviteClosed
			}
			if let member = board.member(of: account) {
				return JoinedBoard(board: key, role: member.boardRole)
			}
			guard board.members.count < SyncLimit.membersPerBoard else {
				throw ServiceError(code: .invalidRequest, message: "Expected a board with room for one more, found \(board.members.count) people")
			}

			let member = BoardMemberRow(board: boardID, account: account, role: invite.boardRole, name: name, now: now)
			try await member.save(on: database)
			ledger.add(member, to: key)
			try await ledger.copyBoard(key, from: owner.$account.id, to: account, on: database)
			if let updated = try await ledger.shared(key, on: database) {
				try await ledger.writeShares(of: updated, on: database)
			}
			ledger.tell([owner.$account.id], about: board, heading: "\(name) joined")
			return JoinedBoard(board: key, role: member.boardRole)
		}
		logger.verbose("Joined a shared board", metadata: ["role": "\(joined.role.rawValue)"])
		return joined
	}
}
