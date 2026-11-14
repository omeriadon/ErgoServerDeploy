//
//  NewerServerProtocolTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 11/11/2026.
//

import ErgoProtocol
import Foundation
import Testing

/// Values a newer server could send that this version has no case for. See `Plans/13-Versions.md`.
struct NewerServerProtocolTests {
	private func decode<Value: Decodable>(_ json: String, as _: Value.Type = Value.self) throws -> Value {
		try ErgoProtocol.decoder.decode(Value.self, from: Data(json.utf8))
	}

	// MARK: - Roles

	@Test func aRoleAddedLaterReadsAsViewer() throws {
		#expect(try decode(#""commenter""#) == BoardRole.viewer)
		#expect(try decode(#""owner""#) == BoardRole.owner)
		#expect(try decode(#""editor""#) == BoardRole.editor)
		#expect(BoardRole(wire: "") == .viewer)
		#expect(!BoardRole(wire: "admin").canEdit)
	}

	@Test func aShareWithARoleAddedLaterIsStillAShare() throws {
		let board = "6F1C2E9A-3B4D-4E5F-8A9B-0C1D2E3F4A5B"
		let me = "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"
		let stamp = SyncStamp(time: 1, counter: 0, device: "server")
		let record = SyncRecord(kind: .share, id: board, fields: [
			SyncFieldName.role: SyncField(value: "commenter", stamp: stamp),
			SyncFieldName.member: SyncField(value: .string(me), stamp: stamp),
			SyncFieldName.members: SyncField(value: [["id": .string(me), "name": "Sam", "role": "commenter"]], stamp: stamp),
		])

		// Without this the board would look like one nobody shared, and every edit would be sent and refused
		let share = try #require(BoardShare(record))
		#expect(share.role == .viewer)
		#expect(share.members.map(\.role) == [.viewer])
	}

	@Test func anInviteToARoleAddedLaterStillReads() throws {
		let preview: BoardInvitePreview = try decode(#"{"board":"b","title":"Rain","ownerName":"Ada","role":"commenter","memberCount":2}"#)
		#expect(preview.role == .viewer)
		#expect(preview.title == "Rain")
	}

	// MARK: - Ask

	@Test func anAnswerMessageOfAnUnknownKindIsUnknown() throws {
		#expect(try decode(#"{"type":"citation","entry":"straw-man"}"#) == AskServerMessage.unknown)
		#expect(try decode(#"{"type":"text","text":"Hello","extra":1}"#) == AskServerMessage.text("Hello"))
	}

	/// None of these ends an answer, so the rest of it still arrives
	@Test(arguments: [
		#"{"type":"boardEdit","edit":{"id":"6F1C2E9A-3B4D-4E5F-8A9B-0C1D2E3F4A5B","change":{"colourCard":{"id":"x"}}}}"#,
		#"{"type":"boardEdit"}"#,
		#"{"type":"tool","tool":7}"#,
		#"{"type":"action","action":{"nonsense":true}}"#,
		#"{"type":"modeRequest","mode":{"reason":"No mode"}}"#,
		#"{"type":"title"}"#,
	])
	func aPartOfAnAnswerThisVersionCantReadIsSkipped(json: String) throws {
		#expect(try decode(json) == AskServerMessage.unknown)
	}

	@Test func aModeAddedLaterIsStillARequestToChange() throws {
		let message: AskServerMessage = try decode(#"{"type":"modeRequest","mode":{"mode":"socratic","reason":"Ask instead of tell"}}"#)
		#expect(message == .modeRequest(AskModeRequest(mode: .normal, reason: "Ask instead of tell")))
	}

	@Test func theEndOfAnAnswerIsNeverSkipped() throws {
		#expect(try decode(#"{"type":"finished","usage":{"tokens":10}}"#) == AskServerMessage.finished)
		#expect(try decode(#"{"type":"failed","error":{"code":"brandNew","message":"Expected something"}}"#)
			== AskServerMessage.failed(ServiceError(code: .internalError, message: "Expected something")))
		#expect(throws: (any Error).self) {
			try decode(#"{"type":"failed"}"#, as: AskServerMessage.self)
		}
		#expect(throws: (any Error).self) {
			try decode(#"{"text":"no type"}"#, as: AskServerMessage.self)
		}
	}

	// MARK: - Accounts

	@Test func aPlanAddedLaterReadsAsFree() throws {
		let usage: UsageStatus = try decode("""
		{"plan":"team","plansEnforced":true,"fractionUsed":0.5,"resets":"2026-11-12T00:00:00Z","deepResearchLeft":1,"deepResearchPerWeek":3,"needsDeviceClaim":false,"seats":5}
		""")
		#expect(usage.plan == .free)
		#expect(!usage.hasPlusFeatures)
	}

	@Test func anErrorCodeAddedLaterIsStillAnError() throws {
		let failure: ServiceError = try decode(#"{"code":"teamSeatsFull","message":"Expected a free seat","seats":5}"#)
		#expect(failure.code == .internalError)
		#expect(failure.message == "Expected a free seat")
	}

	// MARK: - Sync

	@Test func aKindOfRecordAddedLaterIsKeptAsItIs() throws {
		let response: SyncResponse = try decode("""
		{"cursor":9,"more":false,"serverTime":"2026-11-11T00:00:00Z","changes":[
			{"kind":"folder","id":"anything at all","fields":{"colour":{"value":{"deep":[1,2,{"x":null}]},"stamp":{"time":1,"counter":0,"device":"A"}}}}
		],"superseded":[],"somethingNew":true}
		""")
		#expect(response.changes.map(\.kind.rawValue) == ["folder"])
		#expect(response.changes.first?.kind.fieldNames.isEmpty == true)
	}
}
