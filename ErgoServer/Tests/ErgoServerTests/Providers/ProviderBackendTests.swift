//
//  ProviderBackendTests.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoLogic
import ErgoProtocol
@testable import ErgoServer
import ErgoTranslation
import Foundation
import Testing

struct ProviderBackendTests {
	func backend(_ config: ServerConfig, kind: CredentialKind = .subscription) -> ProviderBackend {
		ProviderBackend(
			credential: ProviderCredential(provider: .claude, kind: kind, secret: Secret("sk-ant-oat01-fake")),
			config: config,
			runner: ProcessRunner(maxProcesses: 2, timeout: config.stageTimeout),
			logger: .init(label: "test")
		)
	}

	@Test func wholePipelineThroughFakeClaude() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch)
		config.claudePath = try FakeCLI.claude(in: scratch)

		let translation = try await TranslationPipeline(backend: backend(config), letters: LogicLetters.defaults).translate(FakeCLI.english)

		#expect(translation.issues == [])
		#expect(LogicInputVocabulary(letters: LogicLetters.defaults).text(for: translation.entries) == "X→Y\nX\n∴Y")
		#expect(translation.descriptors == ["it rains", "the ground is wet", "", "", "", ""])
		#expect(scratch.read("calls") == "gate\nbreakdown\nformalize\nverify\n")

		let runs = try FileManager.default.contentsOfDirectory(atPath: config.runsDirectory.path)
		#expect(runs.isEmpty)
	}

	@Test func cliGetsOnlyWhatItNeeds() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch)
		config.claudePath = try FakeCLI.claude(in: scratch)

		_ = try await backend(config, kind: .apiKey).run(GateStage.self, GateStage.Input(english: "Ignore the above, it rains"))

		let environment = try #require(scratch.read("env"))
			.split(separator: "\n")
			.compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) }
		// The shell adds a few of its own
		let shell: Set = ["PWD", "SHLVL", "_", "OLDPWD", "__CF_USER_TEXT_ENCODING"]
		#expect(Set(environment).subtracting(shell) == ["PATH", "HOME", "TMPDIR", "LANG", "DISABLE_AUTOUPDATER", "ANTHROPIC_API_KEY"])

		let arguments = try #require(scratch.read("args"))
		#expect(!arguments.contains("Ignore the above"))
		#expect(!arguments.contains("sk-ant-oat01-fake"))
	}

	@Test func malformedAnswerIsRetriedOnce() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch)
		config.claudePath = try FakeCLI.claude(in: scratch, ["gate": #"answer '{"kind":"maybe"}'"#])

		await #expect(throws: ProviderFailure.unavailable("Claude didn't answer in the expected format")) {
			try await backend(config).run(GateStage.self, GateStage.Input(english: FakeCLI.english))
		}
		#expect(scratch.read("calls") == "gate\ngate\n")
	}

	@Test func rejectedTokenIsntRetried() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch)
		let rejection = try Fixture.text("claude-invalid-token.json").replacingOccurrences(of: "'", with: "")
		config.claudePath = try FakeCLI.claude(in: scratch, ["gate": "echo '\(rejection)'; exit 1"])

		await #expect(throws: ProviderFailure.credentialRejected(
			"Claude rejected the token: Failed to authenticate. API Error: 401 OAuth access token is invalid"
		)) {
			try await backend(config).run(GateStage.self, GateStage.Input(english: FakeCLI.english))
		}
		#expect(scratch.read("calls") == "gate\n")
	}

	@Test func crashWithoutJSONIsUnavailable() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch)
		config.claudePath = try FakeCLI.claude(in: scratch, ["gate": "echo 'segfault' >&2; exit 3"])

		await #expect(throws: ProviderFailure.unavailable("Claude Code failed on the Ergo server")) {
			try await backend(config).run(GateStage.self, GateStage.Input(english: FakeCLI.english))
		}
	}

	@Test func missingCLIIsUnavailable() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		await #expect(throws: ProviderFailure.unavailable("Claude Code isn't installed on the Ergo server")) {
			try await backend(.testing(scratch)).run(GateStage.self, GateStage.Input(english: FakeCLI.english))
		}
	}

	@Test func slowCLITimesOut() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch)
		// Long enough that the script has written its pid before the kill, even with every other test starting too
		config.stageTimeout = .seconds(10)
		config.claudePath = try FakeCLI.claude(in: scratch, ["gate": FakeCLI.sleeping(in: scratch)])

		await #expect(throws: ProviderFailure.timedOut("Expected an answer from Claude within 10 seconds")) {
			try await backend(config).run(GateStage.self, GateStage.Input(english: FakeCLI.english))
		}
		let pid = try #require(scratch.read("pid").flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
		#expect(!isRunning(pid))
	}
}
