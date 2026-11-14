//
//  BoardReportTests.swift
//  ErgoServer
//
//  Created by Adon Omeri on 10/11/2026.
//

import ErgoProtocol
@testable import ErgoServer
import Fluent
import Foundation
import Testing
import VaporTesting

extension Application {
	func report(_ board: String, reason: String, token: String) async throws -> TestingHTTPResponse {
		try await call(.POST, ErgoProtocol.Path.boardReport(board), token: token, body(ReportBoard(reason: reason)))
	}
}

struct BoardReportTests {
	@Test func aMemberCanReport() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.sharing(scratch)) { app in
			let shared = try await app.sharedFixture(role: .viewer)

			let response = try await app.report(shared.board, reason: "  Abuse in the third box \n", token: shared.member.token)
			#expect(response.status == .noContent)

			let report = try #require(try await ReportRow.query(on: app.db).first())
			#expect(try await ReportRow.query(on: app.db).count() == 1)
			#expect(report.reporter == shared.member.accountID)
			#expect(report.owner == shared.owner.accountID)
			#expect(report.board == UUID(uuidString: shared.board))
			#expect(report.reason == "Abuse in the third box")
			#expect(report.handled == nil)
		}
	}

	@Test func theOwnerCanReportToo() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.sharing(scratch)) { app in
			let shared = try await app.sharedFixture()
			#expect(try await app.report(shared.board, reason: "Spam", token: shared.owner.token).status == .noContent)
			#expect(try await ReportRow.query(on: app.db).first()?.reporter == shared.owner.accountID)
		}
	}

	@Test func aStrangerCannot() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.sharing(scratch)) { app in
			let shared = try await app.sharedFixture()
			let stranger = try await app.signedInAccount("stranger")
			// A board that was never shared has no people, so its owner is a stranger to it as well
			let (unshared, _) = try await app.syncedBoard(owner: stranger)

			for board in [shared.board, unshared, newBoardID()] {
				let response = try await app.report(board, reason: "Abuse", token: stranger.token)
				#expect(response.status == .badRequest)
				#expect(try response.decoded(ServiceError.self) == BoardReports.notOnBoard)
			}
			#expect(try await ReportRow.query(on: app.db).count() == 0)
		}
	}

	@Test func aMemberWhoLeftCannot() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.sharing(scratch)) { app in
			let shared = try await app.sharedFixture()
			let removed = try await app.call(.DELETE, ErgoProtocol.Path.boardMember(shared.board, shared.memberID(in: app)), token: shared.owner.token)
			#expect(removed.status == .noContent)

			let response = try await app.report(shared.board, reason: "Abuse", token: shared.member.token)
			#expect(try response.decoded(ServiceError.self) == BoardReports.notOnBoard)
			#expect(try await ReportRow.query(on: app.db).count() == 0)
		}
	}

	@Test func anAnonymousAccountMustSignInFirst() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.sharing(scratch)) { app in
			let shared = try await app.sharedFixture()
			let anonymous = try await app.createAccount()
			let response = try await app.report(shared.board, reason: "Abuse", token: anonymous.token)
			#expect(response.status == .forbidden)
			#expect(try response.decoded(ServiceError.self).code == .signInRequired)
		}
	}

	@Test func theReasonIsOneToAThousandCharacters() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.sharing(scratch)) { app in
			let shared = try await app.sharedFixture()

			for reason in ["", "  \n ", String(repeating: "a", count: 1001)] {
				let response = try await app.report(shared.board, reason: reason, token: shared.member.token)
				#expect(response.status == .badRequest)
				#expect(try response.decoded(ServiceError.self).code == .invalidRequest)
			}
			#expect(try await ReportRow.query(on: app.db).count() == 0)

			// The longest one, and spaces round it don't count
			let longest = String(repeating: "a", count: 1000)
			#expect(try await app.report(shared.board, reason: "  " + longest + "  ", token: shared.member.token).status == .noContent)
			#expect(try await ReportRow.query(on: app.db).first()?.reason == longest)
		}
	}

	@Test func aBodyWithNoReasonIsRefused() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.sharing(scratch)) { app in
			let shared = try await app.sharedFixture()
			let response = try await app.call(.POST, ErgoProtocol.Path.boardReport(shared.board), token: shared.member.token, ByteBuffer(string: "{}"))
			#expect(response.status == .badRequest)
			#expect(try await ReportRow.query(on: app.db).count() == 0)
		}
	}

	@Test func eachAccountHasItsOwnLimit() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.sharing(scratch)
		config.reportsPerHour = 2

		try await withTestApp(config) { app in
			let shared = try await app.sharedFixture()

			for _ in 0 ..< 2 {
				#expect(try await app.report(shared.board, reason: "Abuse", token: shared.member.token).status == .noContent)
			}
			let refused = try await app.report(shared.board, reason: "Abuse", token: shared.member.token)
			#expect(refused.status == .tooManyRequests)
			#expect(try refused.decoded(ServiceError.self).code == .rateLimited)
			#expect(try await ReportRow.query(on: app.db).count() == 2)

			// The owner's reports are counted apart from the member's
			#expect(try await app.report(shared.board, reason: "Abuse", token: shared.owner.token).status == .noContent)
			#expect(try await ReportRow.query(on: app.db).count() == 3)
		}
	}

	@Test func refusedReportsDontUseTheLimitUp() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.sharing(scratch)
		config.reportsPerHour = 1

		try await withTestApp(config) { app in
			let shared = try await app.sharedFixture()
			#expect(try await app.report(shared.board, reason: "", token: shared.member.token).status == .badRequest)
			#expect(try await app.report(newBoardID(), reason: "Abuse", token: shared.member.token).status == .badRequest)
			#expect(try await app.report(shared.board, reason: "Abuse", token: shared.member.token).status == .noContent)
		}
	}

	@Test func aReportOutlivesTheAccountThatSentIt() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.sharing(scratch)) { app in
			let shared = try await app.sharedFixture()
			#expect(try await app.report(shared.board, reason: "Abuse", token: shared.member.token).status == .noContent)

			#expect(try await app.call(.DELETE, ErgoProtocol.Path.account, token: shared.member.token).status == .noContent)
			#expect(try await ReportRow.query(on: app.db).count() == 1)
		}
	}
}

extension SharedFixture {
	/// The id the owner's app sees for the member, which is what removing them takes
	func memberID(in app: Application) async throws -> String {
		let share = try #require(try await app.share(of: board, token: owner.token))
		return try #require(share.members.first { $0.role != .owner }).id.uuidString
	}
}
