//
//  AppUpdateTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 10/11/2026.
//

@testable import ErgoClient
import ErgoProtocol
import Foundation
import Testing

struct AppUpdateTests {
	@Test func aSocketTurnedAwayForItsVersionIsAnOutdatedApp() {
		let failure = ErgoClient.failure(status: 426, error: URLError(.badServerResponse), host: "ergo.example.com")
		#expect(failure.code == .outdatedApp)
	}

	/// A newer server can say things this app has never heard of
	@Test func anUnknownErrorCodeStillDecodes() throws {
		let body = Data(#"{"code":"somethingNew","message":"Expected something else"}"#.utf8)
		let failure = try ErgoProtocol.decoder.decode(ServiceError.self, from: body)

		#expect(failure == ServiceError(code: .internalError, message: "Expected something else"))
	}
}
