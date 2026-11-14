//
//  ReportRow.swift
//  ErgoServer
//
//  Created by Adon Omeri on 10/11/2026.
//

import Fluent
import Foundation

/// Someone on a shared board saying why it's a problem (`POST v1/boards/<board>/report`).
///
/// Nothing sends these anywhere yet: the table is where they wait. Adon will connect it to a mail provider, which should
/// mail every row whose `handled` is empty to whoever looks after the server, and set `handled` once it has.
///
/// No foreign keys, so a report outlives the accounts and the board it names, and is never part of what deleting an
/// account removes. The reason is a stranger's words about someone else's board: never log it.
final class ReportRow: Model, @unchecked Sendable {
	static let schema = "reports"

	@ID(key: .id)
	var id: UUID?

	@Field(key: "created")
	var created: Date

	/// The account that reported it
	@Field(key: "reporter_id")
	var reporter: UUID

	@Field(key: "board_id")
	var board: UUID

	/// Who owned the board when it was reported
	@Field(key: "owner_id")
	var owner: UUID

	/// 1–1,000 characters, trimmed
	@Field(key: "reason")
	var reason: String

	/// When whoever looks after the server dealt with it. Nil until then.
	@OptionalField(key: "handled")
	var handled: Date?

	init() {}

	init(reporter: UUID, board: UUID, owner: UUID, reason: String, now: Date) {
		created = now
		self.reporter = reporter
		self.board = board
		self.owner = owner
		self.reason = reason
	}
}
