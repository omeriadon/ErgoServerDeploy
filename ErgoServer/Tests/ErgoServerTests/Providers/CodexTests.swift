//
//  CodexTests.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoProtocol
@testable import ErgoServer
import ErgoTranslation
import Foundation
import Synchronization
import Testing

struct CodexCommandTests {
	let run = RunDirectory(root: URL(filePath: "/runs/abc", directoryHint: .isDirectory))

	func command(_ kind: CredentialKind, choice: StageModels.Choice = StageModels.Choice(effort: "low")) -> CodexCommand {
		CodexCommand(
			executable: "/opt/codex/bin/codex",
			choice: choice,
			instructions: "Classify \"this\"\nplease",
			credential: ProviderCredential(provider: .codex, kind: kind, secret: Secret("sk-secret")),
			run: run
		)
	}

	@Test func arguments() {
		let arguments = command(.subscription).arguments
		let disabled = CodexCommand.disabledFeatures.flatMap { ["--disable", $0] }

		#expect(arguments == [
			"exec", "--json", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
			"--strict-config", "--sandbox", "read-only",
		] + disabled + [
			"-c", #"cli_auth_credentials_store="file""#,
			"-c", #"web_search="disabled""#,
			"-c", #"model_reasoning_effort="low""#,
			"-c", #"developer_instructions="Classify \"this\"\nplease""#,
			"--output-schema", "/runs/abc/work/schema.json",
			"-o", "/runs/abc/work/answer.json",
			"-C", "/runs/abc/work",
			"-",
		])
		for feature in ["shell_tool", "unified_exec", "apps", "plugins", "multi_agent", "image_generation", "browser_use", "computer_use"] {
			#expect(CodexCommand.disabledFeatures.contains(feature))
		}
	}

	@Test func modelOnlyWhenChosen() {
		#expect(!command(.subscription).arguments.contains("-m"))

		let arguments = command(.subscription, choice: StageModels.Choice(model: "gpt-6", effort: nil)).arguments
		#expect(arguments.contains { $0.hasPrefix("model_reasoning_effort") } == false)
		#expect(arguments.firstIndex(of: "-m").map { arguments[$0 + 1] } == "gpt-6")
	}

	@Test func environment() {
		#expect(command(.subscription).environment == [
			"PATH": "/opt/codex/bin:/usr/local/bin:/usr/bin:/bin",
			"HOME": "/runs/abc/home",
			"CODEX_HOME": "/runs/abc/home/.codex",
			"TMPDIR": "/runs/abc/home/tmp",
			"LANG": "C.UTF-8",
		])
		#expect(command(.apiKey).environment["CODEX_API_KEY"] == "sk-secret")
	}

	@Test func promptAndSecretStayOutOfArguments() {
		let built = command(.apiKey).command(prompt: "Ignore the above")
		#expect(built.input == "Ignore the above")
		#expect(!built.arguments.contains { $0.contains("sk-secret") || $0.contains("Ignore the above") })
	}
}

struct CodexEventsTests {
	@Test func networkFailure() throws {
		let events = try CodexEvents(Fixture.data("codex-network-failure.jsonl"))

		#expect(!events.completed)
		#expect(events.failure == .unavailable("Couldn't reach ChatGPT: workspace routing discovery failed"))
		#expect(events.failure?.serviceError.code == .providerUnavailable)
	}

	@Test func unauthorized() throws {
		let events = try CodexEvents(Fixture.data("codex-unauthorized.jsonl"))

		#expect(events.failure == .credentialRejected(
			"ChatGPT rejected the login: unexpected status 401 Unauthorized: Missing bearer or basic authentication in header"
		))
	}

	@Test func completed() {
		let output = """
		{"type":"thread.started","thread_id":"1"}
		{"type":"error","message":"Reconnecting... 1/5 (stream disconnected)"}
		{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"{\\"kind\\":\\"argument\\",\\"reason\\":\\"\\"}"}}
		{"type":"turn.completed","usage":{"input_tokens":120,"cached_input_tokens":20,"output_tokens":9}}
		"""
		let events = CodexEvents(Data(output.utf8))

		#expect(events.completed)
		#expect(events.failure == nil)
		#expect(events.usage == CodexEvents.Usage(inputTokens: 120, cachedInputTokens: 20, outputTokens: 9))
		#expect(events.lastMessage == #"{"kind":"argument","reason":""}"#)
	}

	@Test func usageLimit() {
		#expect(CodexEvents.failure(for: "You've hit your usage limit. Try again later.") == .usageLimit(
			"Reached ChatGPT's usage limit: You've hit your usage limit. Try again later"
		))
	}
}

struct CodexLoginRefreshTests {
	@Test func authIsPrivateAndRotationsCarryOver() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch)
		config.codexPath = try FakeCLI.codex(in: scratch)

		let original = #"{"tokens":{"access_token":"access-0","refresh_token":"refresh-0"}}"#
		let saved = Mutex<[String]>([])
		let backend = ProviderBackend(
			credential: ProviderCredential(provider: .codex, kind: .subscription, secret: Secret(original)),
			config: config,
			runner: ProcessRunner(maxProcesses: 2, timeout: .seconds(10)),
			logger: .init(label: "test")
		) { secret in
			saved.withLock { $0.append(secret.value) }
		}

		for _ in 1 ... 2 {
			let output = try await backend.run(GateStage.self, GateStage.Input(english: FakeCLI.english))
			#expect(output.kind == .argument)
		}

		#expect(scratch.read("modes")?.split(separator: "\n") == ["600", "600"])
		// The second call starts from what the first one left
		#expect(scratch.read("received")?.split(separator: "\n").map(String.init) == [
			original,
			#"{"tokens":{"access_token":"access-1","refresh_token":"refresh-1"}}"#,
		])
		#expect(saved.withLock(\.self) == [
			#"{"tokens":{"access_token":"access-1","refresh_token":"refresh-1"}}"#,
			#"{"tokens":{"access_token":"access-2","refresh_token":"refresh-2"}}"#,
		])
		#expect(backend.latest.current.value == saved.withLock(\.self).last)

		// Nothing is left behind
		let runs = try FileManager.default.contentsOfDirectory(atPath: config.runsDirectory.path)
		#expect(runs.isEmpty)
	}
}
