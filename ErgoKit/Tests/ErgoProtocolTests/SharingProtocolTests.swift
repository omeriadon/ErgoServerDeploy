//
//  SharingProtocolTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 7/11/2026.
//

import ErgoProtocol
import Foundation
import Testing

/// The shapes board sharing adds, and invite links
struct SharingProtocolTests {
	static let board = "6F1C2E9A-3B4D-4E5F-8A9B-0C1D2E3F4A5B"
	static let date = Date(timeIntervalSince1970: 1_793_836_800)
	static let stamp = SyncStamp(time: 1, counter: 0, device: "server")

	func json(_ value: some Encodable) throws -> String {
		let encoder = ErgoProtocol.encoder
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		return try String(decoding: encoder.encode(value), as: UTF8.self)
	}

	func expectRoundTrip<Value: Codable & Equatable>(_ value: Value, _ snapshot: String) throws {
		#expect(try json(value) == snapshot)
		#expect(try ErgoProtocol.decoder.decode(Value.self, from: Data(snapshot.utf8)) == value)
	}

	func url(_ string: String) throws -> URL {
		try #require(URL(string: string))
	}

	// MARK: - Shapes

	@Test func invites() throws {
		try expectRoundTrip(
			CreateBoardInvite(role: .editor, title: "Rain", name: "Ada"),
			#"{"name":"Ada","role":"editor","title":"Rain"}"#
		)
		try expectRoundTrip(
			BoardInvite(url: url("https://ergo.example.com/join/abc"), role: .viewer, expires: Self.date),
			#"{"expires":"2026-11-05T00:00:00Z","role":"viewer","url":"https://ergo.example.com/join/abc"}"#
		)
		try expectRoundTrip(UpdateBoardMember(role: .viewer), #"{"role":"viewer"}"#)
		try expectRoundTrip(BoardInviteToken(token: "abc"), #"{"token":"abc"}"#)
		try expectRoundTrip(
			BoardInvitePreview(board: Self.board, title: "Rain", ownerName: "Ada", role: .editor, memberCount: 3),
			#"{"board":"\#(Self.board)","memberCount":3,"ownerName":"Ada","role":"editor","title":"Rain"}"#
		)
		try expectRoundTrip(AcceptBoardInvite(token: "abc", name: "Sam"), #"{"name":"Sam","token":"abc"}"#)
		try expectRoundTrip(JoinedBoard(board: Self.board, role: .owner), #"{"board":"\#(Self.board)","role":"owner"}"#)
	}

	@Test func reports() throws {
		try expectRoundTrip(ReportBoard(reason: "Abuse"), #"{"reason":"Abuse"}"#)
		#expect(ErgoProtocol.Path.boardReport("B") == "v1/boards/B/report")
		#expect(try ReportBoard.normalized("  Abuse \n") == "Abuse")
		#expect(throws: ServiceError.self) { try ReportBoard.normalized(" \n ") }
		#expect(try ReportBoard.normalized(String(repeating: "a", count: 1000)).count == 1000)
		#expect(throws: ServiceError.self) { try ReportBoard.normalized(String(repeating: "a", count: 1001)) }
	}

	@Test func pushDevices() throws {
		try expectRoundTrip(PushDevice(token: "ab12"), #"{"token":"ab12"}"#)
	}

	@Test func paths() {
		#expect(ErgoProtocol.Path.boardInvites("B") == "v1/boards/B/invites")
		#expect(ErgoProtocol.Path.boardMember("B", "M") == "v1/boards/B/members/M")
		#expect(ErgoProtocol.Path.boardShare("B") == "v1/boards/B/share")
		#expect(ErgoProtocol.Path.invitePreview == "v1/invites/preview")
		#expect(ErgoProtocol.Path.inviteAccept == "v1/invites/accept")
		#expect(ErgoProtocol.Path.pushDevice == "v1/push/device")
		#expect(ErgoProtocol.Path.appleAppSiteAssociation == ".well-known/apple-app-site-association")
		#expect(ErgoProtocol.Path.join == "join")
	}

	// MARK: - The sync reply

	/// Additive: a reply with none leaves the key out, and a reply from an older server still decodes
	@Test func rejectedIsOptionalOnTheWire() throws {
		let without = SyncResponse(cursor: 1, changes: [], more: false, serverTime: Self.date)
		#expect(try !json(without).contains("rejected"))

		let old = #"{"changes":[],"cursor":1,"more":false,"serverTime":"2026-11-05T00:00:00Z","superseded":[]}"#
		#expect(try ErgoProtocol.decoder.decode(SyncResponse.self, from: Data(old.utf8)) == without)
	}

	@Test func rejectedChanges() throws {
		try expectRoundTrip(RejectedChange(kind: .statement, id: "A"), #"{"id":"A","kind":"statement"}"#)

		let current = SyncRecord(kind: .statement, id: "A", fields: ["content": SyncField(value: "x", stamp: Self.stamp)])
		try expectRoundTrip(
			RejectedChange(kind: .statement, id: "A", current: current),
			#"{"current":{"fields":{"content":{"stamp":{"counter":0,"device":"server","time":1},"value":"x"}},"id":"A","kind":"statement"},"id":"A","kind":"statement"}"#
		)

		let response = SyncResponse(cursor: 1, changes: [], more: false, rejected: [RejectedChange(kind: .link, id: "B")], serverTime: Self.date)
		#expect(try ErgoProtocol.decoder.decode(SyncResponse.self, from: ErgoProtocol.encoder.encode(response)) == response)
	}

	/// ErgoSync's types are one import away, so the app and server needn't import both
	@Test func shareTypesAreReExported() {
		#expect(BoardRole(rawValue: "editor") == .editor)
		#expect(SyncLimit.membersPerBoard == 30)
		#expect(ErgoProtocol.version == 1)
	}

	// MARK: - Links

	@Test(arguments: [
		"https://ergo.example.com/join/abc",
		"https://localhost:8080/join/abc",
		"https://ergo.example.com/join/abc/",
		"ergo://join/abc",
		"ERGO://join/abc",
	])
	func linksGiveTheirToken(link: String) throws {
		#expect(try BoardInviteLink.token(from: url(link)) == "abc")
	}

	@Test(arguments: [
		"http://ergo.example.com/join/abc",
		"https://ergo.example.com/join",
		"https://ergo.example.com/join/",
		"https://ergo.example.com/join/abc/more",
		"https://ergo.example.com/abc",
		"https://ergo.example.com/other/abc",
		"https://ergo.example.com/",
		"ergo://join",
		"ergo://join/",
		"ergo://join/abc/more",
		"ergo://share",
		"ergo://share/abc",
		"ergo:join/abc",
		"mailto:join@example.com",
	])
	func otherLinksGiveNoToken(link: String) throws {
		#expect(try BoardInviteLink.token(from: url(link)) == nil)
	}
}
