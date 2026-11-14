//
//  DeviceLoginTests.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoClient
import ErgoProtocol
@testable import ErgoServer
import Foundation
import Synchronization
import Testing

struct DeviceLoginTests {
	static let login = #"{"OPENAI_API_KEY":null,"tokens":{"id_token":"id","access_token":"access","refresh_token":"refresh","account_id":"account"}}"#

	/// Prints what the real `codex login --device-auth` prints, then runs `then`
	func fakeCodex(in scratch: Scratch, then: String) throws -> String {
		let transcript = try #require(Bundle.module.url(forResource: "codex-device-auth", withExtension: "txt", subdirectory: "Fixtures"))
		return try scratch.script("codex", #"""
		printf '%s\n' "$@" > '\#(scratch.path("args"))'
		cat '\#(transcript.path)'
		\#(then)
		"""#)
	}

	func messages(_ client: ErgoClient) async throws -> [DeviceLoginMessage] {
		var messages: [DeviceLoginMessage] = []
		for try await message in client.codexDeviceLogin() {
			messages.append(message)
		}
		return messages
	}

	@Test func codeThenConnected() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch)
		config.codexPath = try fakeCodex(in: scratch, then: #"""
		sleep 1
		printf '%s' '\#(Self.login)' > "$CODEX_HOME/auth.json"
		"""#)
		let verified = Mutex<[ProviderCredential]>([])
		let verifier = ConnectionVerifier { credential, _ in
			verified.withLock { $0.append(credential) }
			return credential.secret
		}

		try await withLiveServer(config, verifier: verifier) { app, server in
			let account = try await ErgoClient(server: server, token: nil).createAccount()
			let messages = try await messages(ErgoClient(server: server, token: account.token))

			#expect(messages.count == 2)
			#expect(try messages.first == .code(url: #require(URL(string: "https://auth.openai.com/codex/device")), code: "T3ST-C0DE9"))
			guard case let .connected(status)? = messages.last else {
				Issue.record("Expected .connected, found \(messages)")
				return
			}
			#expect(status.provider == .codex)
			#expect(status.kind == .subscription)
			#expect(status.verified != nil)

			#expect(verified.withLock(\.self).map(\.secret.value) == [Self.login])
			#expect(try await app.storedSecret(.codex, account: account.id) == Self.login)
			#expect(scratch.read("args") == "login\n--device-auth\n-c\ncli_auth_credentials_store=\"file\"\n")
		}
	}

	@Test(arguments: [
		(
			"echo 'Error: device code login is not enabled for this workspace.' >&2; exit 1",
			"Expected device code login to be on, turn it on in ChatGPT's security settings"
		),
		("echo 'Error: something broke.'; exit 2", "Couldn't log in to ChatGPT: Error: something broke"),
		("exit 0", "Expected Codex to save the ChatGPT login, found nothing"),
	])
	func failures(then: String, message: String) async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch)
		config.codexPath = try fakeCodex(in: scratch, then: then)

		try await withLiveServer(config) { app, server in
			let account = try await ErgoClient(server: server, token: nil).createAccount()
			let messages = try await messages(ErgoClient(server: server, token: account.token))

			#expect(messages.last == .failed(ServiceError(code: .providerUnavailable, message: message)))
			#expect(try await app.storedSecret(.codex, account: account.id) == nil)
		}
	}

	@Test func rejectedLoginIsntStored() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch)
		config.codexPath = try fakeCodex(in: scratch, then: "printf '%s' '\(Self.login)' > \"$CODEX_HOME/auth.json\"")
		let rejection = ProviderFailure.credentialRejected("ChatGPT rejected the login: token expired")

		try await withLiveServer(config, verifier: .rejecting(rejection)) { app, server in
			let account = try await ErgoClient(server: server, token: nil).createAccount()
			let messages = try await messages(ErgoClient(server: server, token: account.token))

			#expect(messages.last == .failed(rejection.serviceError))
			#expect(try await app.storedSecret(.codex, account: account.id) == nil)
		}
	}

	@Test func closingKillsTheLogin() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch)
		config.codexPath = try fakeCodex(in: scratch, then: FakeCLI.sleeping(in: scratch))

		try await withLiveServer(config) { _, server in
			let account = try await ErgoClient(server: server, token: nil).createAccount()
			let client = ErgoClient(server: server, token: account.token)
			let work = Task { try await messages(client) }

			#expect(try await eventually { scratch.read("child") != nil })
			let cli = try #require(scratch.read("pid").flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
			work.cancel()
			#expect(try await eventually { !isRunning(cli) })
		}
	}

	@Test func scannerReadsTheRealTranscript() throws {
		let scanner = DeviceCodeScanner()
		let found = try Fixture.text("codex-device-auth.txt").split(separator: "\n", omittingEmptySubsequences: false).compactMap {
			scanner.scan(String($0))
		}

		#expect(found.count == 1)
		#expect(found.first?.0 == URL(string: "https://auth.openai.com/codex/device"))
		#expect(found.first?.1 == "T3ST-C0DE9")
	}
}
