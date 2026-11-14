//
//  NewerServerTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 11/11/2026.
//

@testable import ErgoClient
import ErgoProtocol
import ErgoTranslation
import Foundation
import Testing

/// A server newer than this app says things the app has never heard of. The app carries on with what it knows. These
/// are the first public build's promises: none of this can be added to an app that's already out.
struct NewerServerTests {
	private func frame<Message: Decodable>(_ json: String, as _: Message.Type = Message.self) throws -> Message? {
		try ErgoClient.decode(.string(json))
	}

	// MARK: - Sockets

	@Test func aSyncMessageOfAnUnknownKindIsSkipped() throws {
		#expect(try frame(#"{"changed":{"cursor":7}}"#) == SyncLiveMessage.changed(cursor: 7))
		#expect(try frame(#"{"presence":{"member":"6F1C2E9A-3B4D-4E5F-8A9B-0C1D2E3F4A5B"}}"#, as: SyncLiveMessage.self) == nil)
	}

	@Test func aKnownKindWithMoreInItStillReads() throws {
		#expect(try frame(#"{"changed":{"cursor":7,"board":"x","urgent":true}}"#) == SyncLiveMessage.changed(cursor: 7))
	}

	/// Skipping the message a run ends with would wait for ever, so that one still fails
	@Test func aBrokenMessageOfAKnownKindStillFails() {
		#expect(throws: ServiceError.unexpectedReply) {
			try frame(#"{"changed":{"cursor":"seven"}}"#, as: SyncLiveMessage.self)
		}
		#expect(throws: ServiceError.unexpectedReply) {
			try frame(#"{"finished":{"_0":{"nonsense":true}}}"#, as: BreakDownServerMessage.self)
		}
		#expect(throws: ServiceError.unexpectedReply) {
			try frame(#"{"connected":{"_0":{}}}"#, as: DeviceLoginMessage.self)
		}
	}

	@Test(arguments: ["", "null", "[]", "7", "\"text\"", "{}", "{\"a\":1,\"b\":2}", "{", "not json"])
	func whatIsNotAMessageAtAllStillFails(json: String) {
		#expect(throws: ServiceError.unexpectedReply) {
			try frame(json, as: SyncLiveMessage.self)
		}
		#expect(throws: ServiceError.unexpectedReply) {
			try frame(json, as: BreakDownServerMessage.self)
		}
	}

	@Test func progressThisVersionCantReadIsSkipped() throws {
		// A step added later, and a whole kind of event added later
		#expect(try frame(#"{"event":{"_0":{"started":{"step":"rewrite","attempt":1}}}}"#, as: BreakDownServerMessage.self) == nil)
		#expect(try frame(#"{"event":{"_0":{"thinking":{"seconds":3}}}}"#, as: BreakDownServerMessage.self) == nil)
		#expect(try frame(#"{"event":{"_0":{"thinking":{"seconds":3}}}}"#, as: TranslateServerMessage.self) == nil)
		#expect(try frame(#"{"paused":{}}"#, as: BreakDownServerMessage.self) == nil)
	}

	@Test func whatTheServerSendsTodayStillReads() throws {
		let event = TranslationEvent.started(step: .gate, attempt: 1)
		let failure = ServiceError(code: .rateLimited, message: "Expected fewer requests")
		let status = ConnectionStatus(provider: .codex, kind: .subscription, verified: nil, problem: nil)

		func sent(_ message: some Encodable) throws -> String {
			try #require(ErgoClient.text(message))
		}

		#expect(try frame(sent(BreakDownServerMessage.event(event))) == BreakDownServerMessage.event(event))
		#expect(try frame(sent(BreakDownServerMessage.failed(failure))) == BreakDownServerMessage.failed(failure))
		#expect(try frame(sent(TranslateServerMessage.event(event))) == TranslateServerMessage.event(event))
		#expect(try frame(sent(DeviceLoginMessage.connected(status))) == DeviceLoginMessage.connected(status))
		#expect(try frame(sent(DeviceLoginMessage.failed(failure))) == DeviceLoginMessage.failed(failure))
		#expect(try frame(sent(SyncLiveMessage.changed(cursor: 1))) == SyncLiveMessage.changed(cursor: 1))
	}

	/// The names in `kinds` are checked against what Swift really writes, so a renamed case can't go unnoticed
	@Test func theKindsAreTheOnesThatAreWritten() throws {
		func kind(_ message: some Encodable) throws -> String {
			let object = try JSONSerialization.jsonObject(with: ErgoProtocol.encoder.encode(message)) as? [String: Any]
			return try #require(object?.keys.first)
		}
		let failure = ServiceError(code: .internalError, message: "")
		let status = ConnectionStatus(provider: .claude, kind: .apiKey, verified: nil, problem: nil)

		#expect(try SyncLiveMessage.kinds == [kind(SyncLiveMessage.changed(cursor: 1))])
		#expect(try DeviceLoginMessage.kinds == [
			kind(DeviceLoginMessage.code(url: #require(URL(string: "https://example.com")), code: "1")),
			kind(DeviceLoginMessage.connected(status)),
			kind(DeviceLoginMessage.failed(failure)),
		])
		#expect(try BreakDownServerMessage.kinds == [
			kind(BreakDownServerMessage.event(.started(step: .gate, attempt: 1))),
			kind(BreakDownServerMessage.failed(failure)),
			"finished",
		])
		#expect(try BreakDownServerMessage.progressKinds == [kind(BreakDownServerMessage.event(.started(step: .gate, attempt: 1)))])
		#expect(TranslateServerMessage.kinds == BreakDownServerMessage.kinds)
	}

	// MARK: - Lists

	@Test func aConnectionToAnUnknownProviderIsLeftOut() throws {
		let json = """
		[
			{"provider":"claude","kind":"subscription"},
			{"provider":"gemini","kind":"subscription"},
			{"provider":"codex","kind":"oauth"},
			{"provider":"openrouter","kind":"apiKey","problem":"Expected a key"},
			"not a connection",
			null
		]
		"""
		let list = try ErgoProtocol.decoder.decode(TolerantList<ConnectionStatus>.self, from: Data(json.utf8))

		#expect(list.elements.map(\.provider) == [.claude, .openrouter])
		#expect(list.elements.last?.problem == "Expected a key")
	}

	@Test func anEmptyListAndAListOfNothingReadableAreEmpty() throws {
		#expect(try ErgoProtocol.decoder.decode(TolerantList<ConnectionStatus>.self, from: Data("[]".utf8)).elements.isEmpty)
		#expect(try ErgoProtocol.decoder.decode(TolerantList<ConnectionStatus>.self, from: Data("[1,2,[3],{}]".utf8)).elements.isEmpty)
		#expect(throws: (any Error).self) {
			try ErgoProtocol.decoder.decode(TolerantList<ConnectionStatus>.self, from: Data(#"{"provider":"claude"}"#.utf8))
		}
	}
}
