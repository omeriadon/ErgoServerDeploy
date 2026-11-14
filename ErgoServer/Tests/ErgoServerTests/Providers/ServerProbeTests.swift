//
//  ServerProbeTests.swift
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

/// The app's Test Server row, through a real server on a free port and the app's own `ErgoClient`
struct ServerProbeTests {
	@Test func anAccountGetsThroughBoth() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withLiveServer(.testing(scratch)) { _, server in
			let account = try await ErgoClient(server: server, token: nil).createAccount()
			let probe = try await ErgoClient(server: server, token: account.token).probe()
			#expect(probe == ErgoClient.Probe(rest: .ok, socket: .ok))
		}
	}

	/// The probe never makes an account, and being turned away still shows the server was reached
	@Test func noAccountIsReachedButTurnedAway() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withLiveServer(.testing(scratch)) { app, server in
			let probe = try await ErgoClient(server: server, token: nil).probe()
			#expect(probe == ErgoClient.Probe(rest: .noAccount, socket: .noAccount))
			#expect(try await Account.query(on: app.db).count() == 0)
		}
	}

	@Test func aWrongPathSaysWhatTheUpgradeGot() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withLiveServer(.testing(scratch)) { _, server in
			let account = try await ErgoClient(server: server, token: nil).createAccount()
			let probe = try await ErgoClient(server: server.appending(path: "elsewhere"), token: account.token).probe()

			#expect(probe.rest == .failed(ServiceError(code: .invalidRequest, message: "Unknown path '/elsewhere/v1/connections'")))
			#expect(probe.socket == .failed(ServiceError(
				code: .providerUnavailable,
				message: "Couldn't reach the Ergo server: the server answered HTTP 400 to the WebSocket upgrade"
			)))
		}
	}

	@Test func nothingListeningIsConnectionRefused() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		// A port that was just free, so nothing listens on it
		var closed: URL?
		try await withLiveServer(.testing(scratch)) { _, server in
			closed = server
		}
		let probe = try await ErgoClient(server: #require(closed), token: "token").probe(timeout: 5)
		let refused = ErgoClient.Probe.Outcome.failed(ServiceError(
			code: .providerUnavailable,
			message: "Couldn't reach the Ergo server: connection refused, check ErgoServer is running with '--hostname 0.0.0.0'"
		))
		#expect(probe == ErgoClient.Probe(rest: refused, socket: refused))
	}

	/// What to look for on the Mac's console when the app can't translate: a turned-away upgrade for anyone, and every line for
	/// a verbose account
	@Test func upgradesAreLoggedWithTheirStatus() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withLiveServer(.testing(scratch)) { app, server in
			let logs = CapturedLogs()
			app.logger = logs.logger

			// Vapor's own trace lines print request heads, bearer token and all, so only what's on at the default level counts
			func shownLines() -> [String] {
				logs.all.filter { !$0.hasPrefix("trace") && !$0.hasPrefix("debug") }
			}

			// Working as normal, an account that isn't verbose says nothing at all
			let quiet = try await ErgoClient(server: server, token: nil).createAccount()
			_ = try await ErgoClient(server: server, token: quiet.token).probe()
			#expect(!shownLines().contains { $0.contains("/v1/") }, "Expected no request lines for an account that isn't verbose, found \(shownLines())")

			// Being turned away is said, as a warning, and says nothing of whose token it was
			_ = try await ErgoClient(server: server, token: "not-a-token").probe()
			#expect(shownLines().contains { $0.hasPrefix("warning GET /v1/translate 401 (WebSocket upgrade)") })

			// A verbose account's requests are all there, with its real id
			let account = try await ErgoClient(server: server, token: nil).createAccount()
			app.ergo.verbose.remember(account.id)
			_ = try await ErgoClient(server: server, token: account.token).probe()

			let shown = shownLines().joined(separator: "\n")
			#expect(shown.contains("info GET /v1/translate 101 (WebSocket upgrade)"))
			#expect(shown.contains("info GET /v1/connections 200"))
			#expect(shown.contains(account.id.uuidString))
			#expect(!shown.contains(quiet.id.uuidString))
			#expect(!shown.contains(account.token))
			#expect(!shown.contains(quiet.token))
			#expect(!shown.contains("not-a-token"))
		}
	}

	/// URLSession never answered its own pings in testing, so make sure it answers the server's: a missing pong closes
	/// the socket at the next ping, and a real translation takes longer than one
	@Test func slowTranslationsOutlastThePings() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch)
		config.pingInterval = .milliseconds(200)
		config.stageTimeout = .seconds(2)
		config.claudePath = try FakeCLI.claude(in: scratch, ["gate": FakeCLI.sleeping(in: scratch)])

		try await withLiveServer(config) { app, server in
			let account = try await ErgoClient(server: server, token: nil).createAccount()
			try await app.storeCredential("sk-ant-oat01-fake", provider: .claude, kind: .subscription, account: account.id)
			let client = ErgoClient(server: server, token: account.token)

			var messages: [TranslateServerMessage] = []
			let request = TranslateRequest(id: UUID(), english: FakeCLI.english, provider: .claude, letters: LogicLetters.defaults, grammarVersion: LogicGrammar.version)
			for try await message in client.translate(request) {
				messages.append(message)
			}
			#expect(messages.last == .failed(ServiceError(code: .timedOut, message: "Expected an answer from Claude within 2 seconds")))
		}
	}
}
