//
//  EmailClientTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

@testable import ErgoClient
import ErgoProtocol
import Foundation
import Testing

/// Email and password end to end, against the stand-in server inside URLSession
struct EmailClientTests {
	let client = ErgoClient(server: SyncClientTests.server, token: StubServer.signedIn, session: StubServer.session)

	@Test func requestsGoToTheSharedPaths() throws {
		let credentials = StubServer.email
		let register = try client.request("POST", ErgoProtocol.Path.register, body: credentials)

		#expect(register.url?.absoluteString == "https://ergo.example.com/v1/account/register")
		#expect(register.value(forHTTPHeaderField: "Authorization") == "Bearer signed-in")
		#expect(try ErgoProtocol.decoder.decode(EmailCredentials.self, from: #require(register.httpBody)) == credentials)
	}

	@Test func registeringSendsTheEmailAndPassword() async throws {
		try await client.register(email: "new@example.com", password: "correct horse")
	}

	@Test func registeringATakenEmailThrowsEmailInUse() async {
		await #expect(throws: StubServer.emailInUse) {
			try await client.register(email: StubServer.email.email, password: "correct horse")
		}
	}

	@Test func loggingInReturnsTheSignedInAccount() async throws {
		let signedIn = try await client.logIn(email: StubServer.email.email, password: StubServer.email.password)
		#expect(signedIn == SignedIn(accountID: StubServer.account, token: StubServer.signedIn, isNewAccount: false))
	}

	/// The server answers 401 for both, so only the code tells the app whether to forget its token
	@Test func aWrongPasswordIsntAnUnauthorizedToken() async {
		await #expect(throws: StubServer.invalidCredentials) {
			try await client.logIn(email: StubServer.email.email, password: "wrong password")
		}
		#expect(StubServer.invalidCredentials.code != .unauthorized)
	}

	@Test func changingThePasswordSendsBoth() async throws {
		try await client.changePassword(current: StubServer.email.password, new: "another horse")
		await #expect(throws: StubServer.invalidCredentials) {
			try await client.changePassword(current: "wrong password", new: "another horse")
		}
	}
}
