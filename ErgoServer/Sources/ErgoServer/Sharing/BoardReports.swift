//
//  BoardReports.swift
//  ErgoServer
//
//  Created by Adon Omeri on 10/11/2026.
//

import ErgoProtocol
import Fluent
import Foundation
import Logging

/// Saves a member's report of a shared board. It only reads the board's people and writes a `ReportRow`: nobody is told,
/// and the board and its members are left alone, since leaving and removing people are what already stop it.
enum BoardReports {
	/// A stranger and a board that isn't there get the same answer, so a report can't be used to find boards
	static let notOnBoard = ServiceError(code: .invalidRequest, message: "Expected a board you're on, found none with that id")

	/// The owner counts as on the board. Never logs the reason.
	static func file(
		_ body: ReportBoard,
		board: String?,
		account: UUID,
		limiter: CreateAccountLimiter,
		on database: any Database,
		logger: Logger,
		now: Date = .now
	) async throws {
		let boardID = try BoardSharing.boardID(board)
		let reason = try ReportBoard.normalized(body.reason)

		guard let share = try await BoardShareRow.find(boardID, on: database) else {
			throw notOnBoard
		}
		let isMember = try await BoardMemberRow.query(on: database).filter(\.$board.$id == boardID).filter(\.$account.$id == account).count() > 0
		guard isMember else {
			throw notOnBoard
		}
		// Counted here, so only a report that's saved uses one up
		guard limiter.allow(account.uuidString, now: now) else {
			throw ServiceError(code: .rateLimited, message: "Too many reports from this account, try again in an hour")
		}

		let report = ReportRow(reporter: account, board: boardID, owner: share.$owner.id, reason: reason, now: now)
		try await report.save(on: database)
		let id = try report.requireID()
		// The report's id is enough to find it, and the board's would say whose it is
		logger.warning("A board was reported", metadata: ["report": "\(id)"])
	}
}
