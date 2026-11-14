//
//  TranslateSocketTests.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoClient
import ErgoLogic
import ErgoProtocol
@testable import ErgoServer
import ErgoTranslation
import Foundation
import Testing
import VaporTesting

/// Through a real server on a free port and the app's own `ErgoClient`
struct TranslateSocketTests {
	func request(_ provider: Provider = .claude, english: String = FakeCLI.english, grammarVersion: Int = LogicGrammar.version) -> TranslateRequest {
		TranslateRequest(id: UUID(), english: english, provider: provider, letters: LogicLetters.defaults, grammarVersion: grammarVersion)
	}

	func messages(_ client: ErgoClient, _ request: TranslateRequest) async throws -> [TranslateServerMessage] {
		var messages: [TranslateServerMessage] = []
		for try await message in client.translate(request) {
			messages.append(message)
		}
		return messages
	}

	func breakdownMessages(_ client: ErgoClient, _ request: TranslateRequest) async throws -> [BreakDownServerMessage] {
		var messages: [BreakDownServerMessage] = []
		for try await message in client.breakDown(request) {
			messages.append(message)
		}
		return messages
	}

	/// The ground is wet is already P, the fourth slot
	static let named = ["", "", "", "the ground is wet", "", ""]

	/// A signed-in client, with Claude connected unless `connect` is nil
	func signIn(_ app: Application, _ server: URL, connect provider: Provider? = .claude) async throws -> (ErgoClient, AccountCreated) {
		let account = try await ErgoClient(server: server, token: nil).createAccount()
		switch provider {
			case .claude?:
				try await app.storeCredential("sk-ant-oat01-fake", provider: .claude, kind: .subscription, account: account.id)
			case .codex?:
				try await app.storeCredential(
					#"{"tokens":{"access_token":"access-0","refresh_token":"refresh-0"}}"#,
					provider: .codex,
					kind: .subscription,
					account: account.id
				)
			case .openrouter?, nil:
				break
		}
		return (ErgoClient(server: server, token: account.token), account)
	}

	func pid(_ name: String, in scratch: Scratch) -> Int32? {
		scratch.read(name).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
	}

	// MARK: - Translating

	@Test func eventsThenTranslation() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch)
		config.claudePath = try FakeCLI.claude(in: scratch)

		try await withLiveServer(config) { app, server in
			let (client, account) = try await signIn(app, server)
			let messages = try await messages(client, request())

			guard case let .finished(translation)? = messages.last else {
				Issue.record("Expected .finished last, found \(messages)")
				return
			}
			#expect(LogicInputVocabulary(letters: LogicLetters.defaults).text(for: translation.entries) == "X→Y\nX\n∴Y")
			#expect(translation.issues == [])
			#expect(messages == [
				.event(.started(step: .gate, attempt: 1)),
				.event(.started(step: .breakdown, attempt: 1)),
				.event(.foundClaims(
					premises: ["If it rains, the ground is wet", "It rains"],
					conclusion: "the ground is wet",
					descriptors: ["it rains", "the ground is wet", "", "", "", ""]
				)),
				.event(.started(step: .formalize, attempt: 1)),
				.event(.drafted(entries: translation.entries, attempt: 1)),
				.event(.started(step: .verify, attempt: 1)),
				.finished(translation),
			])

			let stored = try #require(try await Credential.find(.claude, for: account.id, on: app.db))
			#expect(stored.verified != nil)
			#expect(stored.problem == nil)
		}
	}

	@Test func codexRefreshesAreSealedAndCarriedOver() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch)
		config.codexPath = try FakeCLI.codex(in: scratch)

		try await withLiveServer(config) { app, server in
			let (client, account) = try await signIn(app, server, connect: .codex)
			let messages = try await messages(client, request(.codex))

			guard case .finished? = messages.last else {
				Issue.record("Expected .finished last, found \(messages)")
				return
			}
			#expect(scratch.read("received")?.split(separator: "\n").count == 4)
			#expect(scratch.read("received")?.split(separator: "\n").last == #"{"tokens":{"access_token":"access-3","refresh_token":"refresh-3"}}"#)
			#expect(try await app.storedSecret(.codex, account: account.id) == #"{"tokens":{"access_token":"access-4","refresh_token":"refresh-4"}}"#)
		}
	}

	@Test func englishThatIsntWorthACall() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch)
		config.claudePath = try FakeCLI.claude(in: scratch)

		try await withLiveServer(config) { app, server in
			let (client, _) = try await signIn(app, server)
			let messages = try await messages(client, request(english: "hello"))

			#expect(messages == [.finished(Translation(
				english: "hello",
				issues: [TranslationIssue(severity: .error, message: "Expected at least one full sentence")]
			))])
			#expect(scratch.read("calls") == nil)
		}
	}

	// MARK: - Descriptors

	@Test func descriptorsReachTheModelAndKeepTheirLetters() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch)
		config.claudePath = try FakeCLI.claude(in: scratch, [
			"formalize": #"answer '{"premises":["X→P","X"],"conclusion":"P"}'"#,
		])

		try await withLiveServer(config) { app, server in
			let (client, _) = try await signIn(app, server)
			var named = request()
			named.descriptors = Self.named
			let messages = try await messages(client, named)

			guard case let .finished(translation)? = messages.last else {
				Issue.record("Expected .finished last, found \(messages)")
				return
			}
			#expect(LogicInputVocabulary(letters: LogicLetters.defaults).text(for: translation.entries) == "X→P\nX\n∴P")
			#expect(translation.descriptors == ["it rains", "", "", "the ground is wet", "", ""])
			#expect(translation.issues == [])

			// The model was told, in the data and not the instructions
			let formalize = try #require(scratch.read("input-formalize"))
			#expect(formalize.contains("\"descriptors\""))
			#expect(formalize.contains("the ground is wet"))
			#expect(formalize.contains("\"letter\" : \"P\""))
			let breakdown = try #require(scratch.read("input-breakdown"))
			#expect(breakdown.contains("\"descriptors\" : [\n    \"the ground is wet\"\n  ]"))
		}
	}

	@Test func noDescriptorsLeavesTheInputsAsTheyWere() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch)
		config.claudePath = try FakeCLI.claude(in: scratch)

		try await withLiveServer(config) { app, server in
			let (client, _) = try await signIn(app, server)
			_ = try await messages(client, request())

			#expect(try #require(scratch.read("input-breakdown")).contains("descriptors") == false)
			#expect(try #require(scratch.read("input-formalize")).contains("\"descriptors\"") == false)
		}
	}

	// MARK: - Breaking down

	@Test func argumentScopeStopsAfterTheBreakdown() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch)
		config.claudePath = try FakeCLI.claude(in: scratch)

		try await withLiveServer(config) { app, server in
			let (client, account) = try await signIn(app, server)
			var named = request()
			named.descriptors = Self.named
			let messages = try await breakdownMessages(client, named)

			let descriptors = ["it rains", "", "", "the ground is wet", "", ""]
			let premises = ["If it rains, the ground is wet", "It rains"]
			#expect(messages == [
				.event(.started(step: .gate, attempt: 1)),
				.event(.started(step: .breakdown, attempt: 1)),
				.event(.foundClaims(premises: premises, conclusion: "the ground is wet", descriptors: descriptors)),
				.finished(ArgumentBreakdown(
					kind: .argument,
					premises: premises,
					conclusion: "the ground is wet",
					claims: [
						BreakdownStage.Output.Claim(meaning: "It rains", descriptor: "it rains"),
						BreakdownStage.Output.Claim(meaning: "The ground is wet", descriptor: "the ground is wet"),
					],
					descriptors: descriptors
				)),
			])
			#expect(scratch.read("calls") == "gate\nbreakdown\n")

			let stored = try #require(try await Credential.find(.claude, for: account.id, on: app.db))
			#expect(stored.verified != nil)
		}
	}

	@Test func argumentScopeAnswersCodexToo() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch)
		config.codexPath = try FakeCLI.codex(in: scratch)

		try await withLiveServer(config) { app, server in
			let (client, _) = try await signIn(app, server, connect: .codex)
			let messages = try await breakdownMessages(client, request(.codex))

			guard case let .finished(breakdown)? = messages.last else {
				Issue.record("Expected .finished last, found \(messages)")
				return
			}
			#expect(breakdown.premises.count == 2)
			#expect(breakdown.descriptors == ["it rains", "the ground is wet", "", "", "", ""])
			#expect(scratch.read("calls") == "gate\nbreakdown\n")
		}
	}

	@Test func statementScopeStillRunsEveryStage() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch)
		config.claudePath = try FakeCLI.claude(in: scratch)

		try await withLiveServer(config) { app, server in
			let (client, _) = try await signIn(app, server)
			var asked = request()
			asked.scope = .argument
			// `translate` is always the statement scope, whatever the request says
			let messages = try await messages(client, asked)

			guard case .finished? = messages.last else {
				Issue.record("Expected .finished last, found \(messages)")
				return
			}
			#expect(scratch.read("calls") == "gate\nbreakdown\nformalize\nverify\n")
		}
	}

	// MARK: - Limits

	@Test func tooLongEnglishNeverReachesTheCLI() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch)
		config.claudePath = try FakeCLI.claude(in: scratch)

		try await withLiveServer(config) { app, server in
			let (client, _) = try await signIn(app, server)
			let long = String(repeating: "It rains. ", count: 200)
			let problem = "Too long to translate, expected at most \(EnglishValidator.characterLimit) characters"
			var named = request(english: long)
			named.descriptors = Self.named

			#expect(try await messages(client, named) == [.finished(Translation(
				english: long,
				issues: [TranslationIssue(severity: .error, message: problem)]
			))])
			#expect(try await breakdownMessages(client, named) == [.finished(ArgumentBreakdown(
				kind: .neither,
				descriptors: Self.named,
				issues: [TranslationIssue(severity: .error, message: problem)]
			))])
			#expect(scratch.read("calls") == nil)
		}
	}

	@Test(arguments: [
		(Array(repeating: "claim", count: 7), "Expected at most 6 descriptors, found 7"),
		(["", String(repeating: "a", count: 33)], "Expected descriptors of at most 32 characters, found 33"),
	])
	func badDescriptorsAreRefusedForBothScopes(descriptors: [String], message: String) async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch)
		config.claudePath = try FakeCLI.claude(in: scratch)

		try await withLiveServer(config) { app, server in
			let (client, _) = try await signIn(app, server)
			var bad = request()
			bad.descriptors = descriptors
			let refusal = ServiceError(code: .invalidRequest, message: message)

			#expect(try await messages(client, bad) == [.failed(refusal)])
			#expect(try await breakdownMessages(client, bad) == [.failed(refusal)])
			#expect(scratch.read("calls") == nil)
		}
	}

	@Test func otherGrammarIsOutdatedForBothScopes() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withLiveServer(.testing(scratch)) { app, server in
			let (client, _) = try await signIn(app, server)
			let old = request(grammarVersion: LogicGrammar.version + 1)

			guard case let .failed(error)? = try await breakdownMessages(client, old).first else {
				Issue.record("Expected .failed")
				return
			}
			#expect(error.code == .outdatedApp)
		}
	}

	@Test func argumentScopeNeedsAConnection() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withLiveServer(.testing(scratch)) { app, server in
			let (client, _) = try await signIn(app, server, connect: nil)

			#expect(try await breakdownMessages(client, request()) == [
				.failed(ServiceError(code: .notConnected, message: "Claude isn't connected")),
			])
		}
	}

	@Test func cancellingAnArgumentKillsTheCLI() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch)
		config.claudePath = try FakeCLI.claude(in: scratch, ["gate": FakeCLI.sleeping(in: scratch)])

		try await withLiveServer(config) { app, server in
			let (client, _) = try await signIn(app, server)
			let work = Task { try await breakdownMessages(client, request()) }

			#expect(try await eventually { pid("child", in: scratch) != nil })
			let cli = try #require(pid("pid", in: scratch))
			#expect(isRunning(cli))

			work.cancel()
			#expect(try await eventually { !isRunning(cli) })
		}
	}

	@Test func aBreakdownCarriesOnWhenItsSocketCloses() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch)
		config.claudePath = try FakeCLI.claude(in: scratch, ["gate": FakeCLI.sleeping(in: scratch)])

		try await withLiveServer(config) { app, server in
			let (client, account) = try await signIn(app, server)
			var asked = request()
			asked.scope = .argument

			var url = try #require(URLComponents(url: server.appending(path: ErgoProtocol.Path.translate), resolvingAgainstBaseURL: false))
			url.scheme = "ws"
			var socketRequest = try URLRequest(url: #require(url.url))
			socketRequest.setValue(String(ErgoProtocol.version), forHTTPHeaderField: ErgoProtocol.versionHeader)
			socketRequest.setValue("Bearer \(account.token)", forHTTPHeaderField: "Authorization")

			// An app that is force quit: the connection just ends, and no `cancel` is sent
			let socket = URLSession.shared.webSocketTask(with: socketRequest)
			socket.resume()
			let opening = try ErgoProtocol.encoder.encode(TranslateClientMessage.translate(asked))
			try await socket.send(.string(String(decoding: opening, as: UTF8.self)))
			#expect(try await eventually { pid("pid", in: scratch) != nil })
			let cli = try #require(pid("pid", in: scratch))
			socket.cancel(with: .goingAway, reason: nil)

			try await Task.sleep(for: .seconds(1))
			#expect(isRunning(cli))

			// The app comes back and sends the same request, which joins the run. Cancelling that is what stops it.
			let again = Task { try await breakdownMessages(client, asked) }
			try await Task.sleep(for: .milliseconds(500))
			#expect(isRunning(cli))
			again.cancel()
			#expect(try await eventually { !isRunning(cli) })
		}
	}

	// MARK: - Refusing

	@Test(arguments: [Provider.claude, .codex])
	func notConnected(provider: Provider) async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withLiveServer(.testing(scratch)) { app, server in
			let (client, _) = try await signIn(app, server, connect: nil)
			let name = provider == .claude ? "Claude" : "ChatGPT"

			#expect(try await messages(client, request(provider)) == [
				.failed(ServiceError(code: .notConnected, message: "\(name) isn't connected")),
			])
		}
	}

	@Test func otherGrammarIsOutdated() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withLiveServer(.testing(scratch)) { app, server in
			let (client, _) = try await signIn(app, server)
			let messages = try await messages(client, request(grammarVersion: LogicGrammar.version + 1))

			#expect(messages.count == 1)
			guard case let .failed(error)? = messages.first else {
				Issue.record("Expected .failed, found \(messages)")
				return
			}
			#expect(error.code == .outdatedApp)
		}
	}

	@Test func unknownAccountCantConnect() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withLiveServer(.testing(scratch)) { _, server in
			await #expect(throws: ServiceError(code: .unauthorized, message: "Unknown Ergo account")) {
				try await messages(ErgoClient(server: server, token: "nope"), request())
			}
		}
	}

	@Test func rejectedTokenIsRecorded() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch)
		let rejection = try Fixture.text("claude-invalid-token.json")
		config.claudePath = try FakeCLI.claude(in: scratch, ["gate": "echo '\(rejection)'; exit 1"])

		try await withLiveServer(config) { app, server in
			let (client, _) = try await signIn(app, server)
			let messages = try await messages(client, request())
			let problem = "Claude rejected the token: Failed to authenticate. API Error: 401 OAuth access token is invalid"

			#expect(messages.last == .failed(ServiceError(code: .credentialRejected, message: problem)))
			#expect(try await client.connections().map(\.problem) == [problem])
		}
	}

	// MARK: - Stopping

	@Test func secondTranslationIsBusy() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch)
		config.claudePath = try FakeCLI.claude(in: scratch, ["gate": FakeCLI.sleeping(in: scratch)])

		try await withLiveServer(config) { app, server in
			let (client, _) = try await signIn(app, server)
			let first = Task { try await messages(client, request()) }
			defer { first.cancel() }
			#expect(try await eventually { pid("pid", in: scratch) != nil })

			#expect(try await messages(client, request()) == [
				.failed(ServiceError(code: .busy, message: "Expected one translation at a time, another one is still running")),
			])
		}
	}

	@Test func cancellingKillsTheCLI() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch)
		config.claudePath = try FakeCLI.claude(in: scratch, ["gate": FakeCLI.sleeping(in: scratch)])

		try await withLiveServer(config) { app, server in
			let (client, _) = try await signIn(app, server)
			let work = Task { try await messages(client, request()) }

			#expect(try await eventually { pid("child", in: scratch) != nil })
			let cli = try #require(pid("pid", in: scratch))
			let child = try #require(pid("child", in: scratch))
			#expect(isRunning(cli))

			work.cancel()
			#expect(try await eventually { !isRunning(cli) && !isRunning(child) })

			// The account is free again
			#expect(try await eventually { await (try? messages(client, request(english: "hello")))?.count == 1 })
		}
	}

	@Test func slowCLITimesOut() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch)
		// Long enough that the script has written its pid before the kill, even with every other test starting too
		config.stageTimeout = .seconds(10)
		config.claudePath = try FakeCLI.claude(in: scratch, ["gate": FakeCLI.sleeping(in: scratch)])

		try await withLiveServer(config) { app, server in
			let (client, _) = try await signIn(app, server)

			#expect(try await messages(client, request()) == [
				.event(.started(step: .gate, attempt: 1)),
				.failed(ServiceError(code: .timedOut, message: "Expected an answer from Claude within 10 seconds")),
			])
			let cli = try #require(pid("pid", in: scratch))
			#expect(!isRunning(cli))
		}
	}

	@Test func silentClientTimesOut() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch)
		config.requestWait = .seconds(1)

		try await withLiveServer(config) { _, server in
			let account = try await ErgoClient(server: server, token: nil).createAccount()

			var url = try #require(URLComponents(url: server.appending(path: ErgoProtocol.Path.translate), resolvingAgainstBaseURL: false))
			url.scheme = "ws"
			var socketRequest = try URLRequest(url: #require(url.url))
			socketRequest.setValue(String(ErgoProtocol.version), forHTTPHeaderField: ErgoProtocol.versionHeader)
			socketRequest.setValue("Bearer \(account.token)", forHTTPHeaderField: "Authorization")

			let socket = URLSession.shared.webSocketTask(with: socketRequest)
			socket.resume()
			defer { socket.cancel(with: .normalClosure, reason: nil) }

			guard case let .string(text) = try await socket.receive() else {
				Issue.record("Expected a text message")
				return
			}
			#expect(try ErgoProtocol.decoder.decode(TranslateServerMessage.self, from: Data(text.utf8)) == .failed(ServiceError(
				code: .timedOut,
				message: "Expected a translate request within 1 second"
			)))
		}
	}
}
