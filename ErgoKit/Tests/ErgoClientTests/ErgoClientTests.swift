//
//  ErgoClientTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

@testable import ErgoClient
import ErgoProtocol
import Foundation
import Testing

/// Only what can be checked without a server: where requests go and what they carry
struct ErgoClientTests {
	let client = ErgoClient(server: URL(string: "https://ergo.example.com/api")!, token: "token")

	@Test func restRequestsCarryTheHeaders() {
		let request = client.request("GET", ErgoProtocol.Path.connections)

		#expect(request.url?.absoluteString == "https://ergo.example.com/api/v1/connections")
		#expect(request.httpMethod == "GET")
		#expect(request.value(forHTTPHeaderField: "Ergo-Protocol-Version") == "1")
		#expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
	}

	@Test func creatingAnAccountIsntAuthorized() {
		let request = client.request("POST", ErgoProtocol.Path.accounts, authorized: false)

		#expect(request.value(forHTTPHeaderField: "Authorization") == nil)
		#expect(request.value(forHTTPHeaderField: "Ergo-Protocol-Version") == "1")
	}

	@Test func noTokenMeansNoAuthorization() throws {
		let anonymous = try ErgoClient(server: #require(URL(string: "https://ergo.example.com")), token: nil)
		#expect(anonymous.request("GET", ErgoProtocol.Path.connections).value(forHTTPHeaderField: "Authorization") == nil)
	}

	@Test func connectingSendsTheUpload() throws {
		let upload = ConnectionUpload(kind: .subscription, secret: "sk-ant")
		let request = try client.request("PUT", ErgoClient.connectionPath(.claude), body: upload)

		#expect(request.url?.absoluteString == "https://ergo.example.com/api/v1/connections/claude")
		#expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
		#expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
		#expect(try ErgoProtocol.decoder.decode(ConnectionUpload.self, from: #require(request.httpBody)) == upload)
	}

	@Test func socketsUseWebSocketSchemes() throws {
		let secure = client.socketRequest(ErgoProtocol.Path.translate)
		#expect(secure.url?.absoluteString == "wss://ergo.example.com/api/v1/translate")
		#expect(secure.value(forHTTPHeaderField: "Ergo-Protocol-Version") == "1")
		#expect(secure.value(forHTTPHeaderField: "Authorization") == "Bearer token")

		let local = try ErgoClient(server: #require(URL(string: "http://localhost:8080")), token: "token")
		#expect(local.socketRequest(ErgoProtocol.Path.deviceLogin).url?.absoluteString == "ws://localhost:8080/v1/connections/codex/device-login")
	}

	@Test func socketMessagesAreJSONText() throws {
		let request = TranslateRequest(id: UUID(), english: "It rains.", provider: .claude, letters: ["X"], grammarVersion: 1)
		let text = try #require(ErgoClient.text(TranslateClientMessage.translate(request)))
		#expect(try ErgoProtocol.decoder.decode(TranslateClientMessage.self, from: Data(text.utf8)) == .translate(request))
		#expect(ErgoClient.text(TranslateClientMessage.cancel) == #"{"cancel":{}}"#)
	}

	/// Both are optional for the app, and default to one statement with nothing named
	@Test func requestsDefaultToAStatementWithNoDescriptors() throws {
		let request = TranslateRequest(id: UUID(), english: "It rains.", provider: .claude, letters: ["X"], grammarVersion: 1)
		#expect(request.scope == .statement)
		#expect(request.descriptors == nil)

		let argument = TranslateRequest(
			id: UUID(),
			english: "It rains, so it pours.",
			provider: .claude,
			letters: ["X"],
			grammarVersion: 1,
			descriptors: ["it rains", "", "", "", "", ""],
			scope: .argument
		)
		let text = try #require(ErgoClient.text(TranslateClientMessage.translate(argument)))
		#expect(text.contains(#""scope":"argument""#))
		#expect(try ErgoProtocol.decoder.decode(TranslateClientMessage.self, from: Data(text.utf8)) == .translate(argument))
	}
}
