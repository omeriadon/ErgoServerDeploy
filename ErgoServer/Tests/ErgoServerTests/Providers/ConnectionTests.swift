//
//  ConnectionTests.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoProtocol
@testable import ErgoServer
import Foundation
import Synchronization
import Testing
import VaporTesting

struct ConnectionTests {
	static let codexLogin = #"{"OPENAI_API_KEY":null,"tokens":{"id_token":"id","access_token":"access","refresh_token":"refresh","account_id":"account"},"last_refresh":"2026-11-05T00:00:00Z"}"#

	// MARK: - Shapes

	@Test(arguments: [
		(Provider.claude, CredentialKind.subscription, "sk-ant-api03-abc", "Expected a token from 'claude setup-token', found an API key"),
		(.claude, .subscription, "hello", "Expected a token from 'claude setup-token', starting with 'sk-ant-oat'"),
		(.claude, .apiKey, "sk-ant-oat01-abc", "Expected an Anthropic API key, found a token from 'claude setup-token'"),
		(.claude, .apiKey, "sk-proj-abc", "Expected an Anthropic API key, starting with 'sk-ant-api'"),
		(.codex, .apiKey, "sk-ant-api03-abc", "Expected an OpenAI API key, found an Anthropic one"),
		(.codex, .apiKey, codexLogin, "Expected an OpenAI API key, found 'auth.json', connect it as a ChatGPT login instead"),
		(.codex, .apiKey, "abc", "Expected an OpenAI API key, starting with 'sk-'"),
		(.codex, .subscription, "sk-proj-abc", "Expected the contents of '~/.codex/auth.json', found an API key"),
		(.codex, .subscription, "{nope", "Expected the contents of '~/.codex/auth.json', found something that isn't JSON"),
		(.codex, .subscription, #"{"OPENAI_API_KEY":"sk-abc","tokens":null}"#, "Expected a ChatGPT login in 'auth.json', found an API key, connect it as an API key instead"),
		(.codex, .subscription, #"{"tokens":{"access_token":"a"}}"#, "Expected an access and a refresh token in 'auth.json'"),
		(.claude, .subscription, "sk-ant-oat01 abc", "Expected a single token, found spaces or line breaks inside it"),
		(.claude, .subscription, "", "Expected a secret, found nothing"),
	])
	func shapeProblems(provider: Provider, kind: CredentialKind, secret: String, problem: String) {
		#expect(ConnectionController.problem(with: secret, kind: kind, for: provider) == problem)
	}

	@Test(arguments: [
		(Provider.claude, CredentialKind.subscription, "sk-ant-oat01-abc"),
		(.claude, .apiKey, "sk-ant-api03-abc"),
		(.codex, .apiKey, "sk-proj-abc"),
		(.codex, .subscription, codexLogin),
	])
	func rightShapesPass(provider: Provider, kind: CredentialKind, secret: String) {
		#expect(ConnectionController.problem(with: secret, kind: kind, for: provider) == nil)
	}

	// MARK: - Routes

	@Test func connectingVerifiesThenStores() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		let verified = Mutex<[ProviderCredential]>([])
		let verifier = ConnectionVerifier { credential, _ in
			verified.withLock { $0.append(credential) }
			return credential.secret
		}

		try await withTestApp(.testing(scratch), verifier: verifier) { app in
			let account = try await app.createAccount()
			let upload = ConnectionUpload(kind: .subscription, secret: "  sk-ant-oat01-fake\n")

			try await app.testing().test(.PUT, "v1/connections/claude", headers: .signedIn(account.token), body: body(upload)) { response async throws in
				#expect(response.status == .ok)
				let status = try response.decoded(ConnectionStatus.self)
				#expect(status.provider == .claude)
				#expect(status.kind == .subscription)
				#expect(status.verified != nil)
				#expect(status.problem == nil)
			}

			#expect(verified.withLock(\.self).map(\.secret.value) == ["sk-ant-oat01-fake"])
			#expect(try await app.storedSecret(.claude, account: account.id) == "sk-ant-oat01-fake")

			try await app.testing().test(.GET, ErgoProtocol.Path.connections, headers: .signedIn(account.token)) { response async throws in
				#expect(try response.decoded([ConnectionStatus].self).map(\.provider) == [.claude])
			}
		}
	}

	@Test func badShapeNeverReachesTheVerifier() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch), verifier: .rejecting(.unavailable("Shouldn't be called"))) { app in
			let account = try await app.createAccount()
			let upload = ConnectionUpload(kind: .subscription, secret: "sk-ant-api03-fake")

			try await app.testing().test(.PUT, "v1/connections/claude", headers: .signedIn(account.token), body: body(upload)) { response async throws in
				#expect(response.status == .badRequest)
				#expect(try response.decoded(ServiceError.self) == ServiceError(
					code: .invalidRequest,
					message: "Expected a token from 'claude setup-token', found an API key"
				))
			}
		}
	}

	@Test func rejectionKeepsTheWorkingConnection() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		let rejection = ProviderFailure.credentialRejected("Claude rejected the token: OAuth access token is invalid")

		try await withTestApp(.testing(scratch), verifier: .rejecting(rejection)) { app in
			let account = try await app.createAccount()
			try await app.storeCredential("sk-ant-oat01-working", provider: .claude, kind: .subscription, account: account.id)
			let upload = ConnectionUpload(kind: .subscription, secret: "sk-ant-oat01-typo")

			try await app.testing().test(.PUT, "v1/connections/claude", headers: .signedIn(account.token), body: body(upload)) { response async throws in
				#expect(response.status == .unprocessableEntity)
				#expect(try response.decoded(ServiceError.self) == rejection.serviceError)
			}

			try await app.testing().test(.GET, ErgoProtocol.Path.connections, headers: .signedIn(account.token)) { response async throws in
				let statuses = try response.decoded([ConnectionStatus].self)
				#expect(statuses.count == 1)
				#expect(statuses.first?.problem == nil)
			}
			#expect(try await app.storedSecret(.claude, account: account.id) == "sk-ant-oat01-working")
		}
	}

	@Test func refreshedSecretIsWhatsStored() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		let refreshed = #"{"tokens":{"access_token":"new","refresh_token":"new"}}"#

		try await withTestApp(.testing(scratch), verifier: ConnectionVerifier { _, _ in Secret(refreshed) }) { app in
			let account = try await app.createAccount()
			let upload = ConnectionUpload(kind: .subscription, secret: Self.codexLogin)

			try await app.testing().test(.PUT, "v1/connections/codex", headers: .signedIn(account.token), body: body(upload)) { response async throws in
				#expect(response.status == .ok)
			}
			#expect(try await app.storedSecret(.codex, account: account.id) == refreshed)
		}
	}

	@Test func disconnecting() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let account = try await app.createAccount()
			try await app.storeCredential("sk-ant-oat01-fake", provider: .claude, kind: .subscription, account: account.id)
			try await app.storeCredential("sk-proj-fake", provider: .codex, kind: .apiKey, account: account.id)

			try await app.testing().test(.DELETE, "v1/connections/claude", headers: .signedIn(account.token)) { response async throws in
				#expect(response.status == .noContent)
			}
			try await app.testing().test(.GET, ErgoProtocol.Path.connections, headers: .signedIn(account.token)) { response async throws in
				#expect(try response.decoded([ConnectionStatus].self).map(\.provider) == [.codex])
			}
		}
	}

	@Test func unknownProvider() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withTestApp(.testing(scratch)) { app in
			let account = try await app.createAccount()

			try await app.testing().test(.DELETE, "v1/connections/gemini", headers: .signedIn(account.token)) { response async throws in
				#expect(response.status == .badRequest)
				#expect(try response.decoded(ServiceError.self).message == "Unknown provider 'gemini', expected 'claude' or 'codex'")
			}
		}
	}
}
