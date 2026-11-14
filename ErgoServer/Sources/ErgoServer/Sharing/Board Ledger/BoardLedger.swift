//
//  BoardLedger.swift
//  ErgoServer
//
//  Created by Adon Omeri on 7/11/2026.
//

import ErgoProtocol
import Fluent
import Foundation
import Logging

/// A shared board as this transaction sees it
struct SharedBoard: Sendable {
	/// The board's id as records have it, an uppercase UUID string
	let key: String
	let share: BoardShareRow
	var members: [BoardMemberRow]

	func member(of account: UUID) -> BoardMemberRow? {
		members.first { $0.$account.id == account }
	}

	var owner: BoardMemberRow? {
		member(of: share.$owner.id)
	}

	/// Every member's account but this one
	func others(than account: UUID) -> [UUID] {
		members.map(\.$account.id).filter { $0 != account }
	}

	/// What a `share` record's `members` holds: the owner, then by when they joined
	var everyone: [BoardMember] {
		let ownerID = share.$owner.id
		return members
			.sorted { a, b in
				let aIsOwner = a.$account.id == ownerID
				let bIsOwner = b.$account.id == ownerID
				if aIsOwner != bIsOwner {
					return aIsOwner
				}
				if a.joined != b.joined {
					return a.joined < b.joined
				}
				return (a.id?.uuidString ?? "") < (b.id?.uuidString ?? "")
			}
			.compactMap { row in
				row.id.map { BoardMember(id: $0, name: row.name, role: row.boardRole) }
			}
	}

	/// Nil when there's none to show. Never logged.
	func title(_ vault: CredentialVault) -> String? {
		guard let sealed = share.sealedTitle, let id = share.id, let title = try? vault.openTitle(sealed, board: id), !title.isEmpty else {
			return nil
		}
		return title
	}
}

/// What one transaction on shared boards has done, and writes it: every account it touches is locked, every record
/// takes that account's next seq, and what to tell people comes out at the end, to be done after the commit.
///
/// A value made inside the transaction and never leaving it, except for its `Effects`.
struct BoardLedger: Sendable {
	struct Effects: Sendable {
		/// Each account whose seq moved, and where it ended up
		var cursors: [UUID: Int] = [:]
		var pushes: [PushEvent] = []
	}

	let vault: CredentialVault
	let logger: Logger
	let now: Date

	/// Every account locked so far, one object each, so their seqs only ever count up
	var accounts: [UUID: Account] = [:]
	var changed: Set<UUID> = []
	var pushes: [PushEvent] = []

	/// Boards read so far. Rereads are wasted work, and these are kept current as members change.
	var shares: [String: SharedBoard] = [:]
	var unshared: Set<String> = []

	/// Board → who pushed the edits, to tell the others once at the end
	var edited: [String: UUID] = [:]

	init(vault: CredentialVault, logger: Logger, now: Date = .now) {
		self.vault = vault
		self.logger = logger
		self.now = now
	}

	// MARK: - Locks

	/// In sorted order, so two requests locking the same accounts can't deadlock on Postgres. An account that's gone is skipped.
	mutating func lock(_ ids: some Sequence<UUID>, on database: any Database) async throws {
		for id in Set(ids).sorted(by: { $0.uuidString < $1.uuidString }) where accounts[id] == nil {
			accounts[id] = try await Self.lockIfThere(id, on: database)
		}
	}

	/// The same order, for a transaction that only needs them held
	static func lockInOrder(_ ids: some Sequence<UUID>, on database: any Database) async throws {
		for id in Set(ids).sorted(by: { $0.uuidString < $1.uuidString }) {
			_ = try await lockIfThere(id, on: database)
		}
	}

	static func lockIfThere(_ id: UUID, on database: any Database) async throws -> Account? {
		do {
			return try await SyncService.lock(id, on: database)
		} catch let error as ServiceError where error == .unknownAccount {
			return nil
		}
	}

	// MARK: - Finishing

	/// Tells someone something, on a board that may be gone by the time it's sent
	mutating func tell(_ recipients: [UUID], about board: SharedBoard, heading: String) {
		guard !recipients.isEmpty else { return }
		pushes.append(PushEvent(board: board.key, heading: heading, title: board.title(vault), recipients: recipients))
	}

	/// Tells someone something that isn't about a shared board's people. `body` is never logged.
	mutating func alert(_ recipients: [UUID], board: String, heading: String, body: String) {
		guard !recipients.isEmpty else { return }
		pushes.append(PushEvent(board: board, heading: heading, title: body, recipients: recipients))
	}

	/// Wakes devices that have no open socket so they sync, with no alert
	mutating func syncSilently(_ recipients: [UUID], board: String) {
		guard !recipients.isEmpty else { return }
		var event = PushEvent(board: board, heading: "", title: nil, recipients: recipients)
		event.isSilent = true
		pushes.append(event)
	}

	/// Saves every account that changed. The last thing in the transaction but reading, since the seqs are final now.
	mutating func finish(on database: any Database) async throws -> Effects {
		var cursors: [UUID: Int] = [:]
		for id in changed {
			guard let account = accounts[id] else { continue }
			try await account.save(on: database)
			cursors[id] = account.seq
		}
		for (key, editor) in edited {
			guard let board = shares[key], let name = board.member(of: editor)?.name else { continue }
			var event = PushEvent(board: key, heading: "\(name) edited", title: board.title(vault), recipients: board.others(than: editor))
			event.isEdit = true
			pushes.append(event)
		}
		return Effects(cursors: cursors, pushes: pushes)
	}
}
