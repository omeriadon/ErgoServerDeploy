//
//  CodexCommand.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoProtocol
import Foundation

/// One `codex exec` call, with everything that could touch the machine turned off and a read-only sandbox
/// around the rest. Codex has no system prompt flag, so the instructions go in as developer instructions.
struct CodexCommand {
	let executable: String
	let choice: StageModels.Choice
	let instructions: String
	let credential: ProviderCredential
	let run: RunDirectory

	/// The URL of Ergo's own tools, for ask. They're the only ones it can use, and with them the answer is free text
	/// rather than a schema's JSON.
	var tools: String?

	/// Every tool-like feature in codex-cli 0.166, from `codex features list`
	static let disabledFeatures = [
		"shell_tool", "unified_exec", "apps", "plugins", "multi_agent",
		"image_generation", "browser_use", "computer_use", "view_image", "in_app_browser",
	]

	var codexHome: URL {
		run.home.appending(path: ".codex", directoryHint: .isDirectory)
	}

	var authFile: URL {
		codexHome.appending(path: CodexAuthFile.name)
	}

	var schemaFile: URL {
		run.work.appending(path: "schema.json")
	}

	var answerFile: URL {
		run.work.appending(path: "answer.json")
	}

	var arguments: [String] {
		var arguments = [
			"exec",
			"--json",
			"--ephemeral",
			"--skip-git-repo-check",
			"--ignore-user-config",
			"--ignore-rules",
			// A setting Codex no longer knows fails the call, instead of quietly leaving a tool on
			"--strict-config",
			"--sandbox", "read-only",
		]
		for feature in Self.disabledFeatures {
			arguments += ["--disable", feature]
		}
		arguments += Self.settings(
			[
				("cli_auth_credentials_store", "file"),
				("web_search", "disabled"),
				choice.effort.map { ("model_reasoning_effort", $0) },
				("developer_instructions", instructions),
				tools.map { ("mcp_servers.ergo.url", $0) },
				tools.map { _ in ("mcp_servers.ergo.default_tools_approval_mode", "approve") },
				tools.map { _ in ("approval_policy", "never") },
			]
		)
		if let model = choice.model {
			arguments += ["-m", model]
		}
		if tools == nil {
			arguments += [
				"--output-schema", schemaFile.path,
				"-o", answerFile.path,
			]
		}
		arguments += [
			"-C", run.work.path,
			// The prompt comes on stdin
			"-",
		]
		return arguments
	}

	var environment: [String: String] {
		var environment = Self.environment(home: run.home, codexHome: codexHome, executable: executable)
		if credential.kind == .apiKey {
			environment["CODEX_API_KEY"] = credential.secret.value
		}
		return environment
	}

	func command(prompt: String) -> ProcessRunner.Command {
		ProcessRunner.Command(executable: executable, arguments: arguments, environment: environment, directory: run.work, input: prompt)
	}

	// MARK: - App server

	/// `codex app-server`, the only way it reports tokens as they're written, for ask. It has no `exec`-style flags, so
	/// everything `arguments` turns off goes in as settings. It doesn't read `CODEX_API_KEY`, so it's for logins only.
	var appServerCommand: ProcessRunner.Command {
		var arguments = ["app-server"]
		for feature in Self.disabledFeatures {
			arguments += ["-c", "features.\(feature)=false"]
		}
		arguments += Self.settings(
			[
				("cli_auth_credentials_store", "file"),
				("web_search", "disabled"),
				("sandbox_mode", "read-only"),
				("approval_policy", "never"),
				choice.model.map { ("model", $0) },
				choice.effort.map { ("model_reasoning_effort", $0) },
				("developer_instructions", instructions),
				tools.map { ("mcp_servers.ergo.url", $0) },
				tools.map { _ in ("mcp_servers.ergo.default_tools_approval_mode", "approve") },
			]
		)
		return ProcessRunner.Command(executable: executable, arguments: arguments, environment: environment, directory: run.work)
	}

	// MARK: - Shared with device login

	/// Built from nothing, like Claude's
	static func environment(home: URL, codexHome: URL, executable: String) -> [String: String] {
		[
			"PATH": ClaudeCodeCommand.path(for: executable),
			"HOME": home.path,
			"CODEX_HOME": codexHome.path,
			"TMPDIR": home.appending(path: "tmp").path,
			"LANG": "C.UTF-8",
		]
	}

	/// `-c key=value` pairs, each value written as a TOML string so quotes and newlines survive
	static func settings(_ pairs: [(String, String)?]) -> [String] {
		pairs.compactMap(\.self).flatMap { ["-c", "\($0.0)=\(tomlString($0.1))"] }
	}

	static func tomlString(_ text: String) -> String {
		var quoted = "\""
		for scalar in text.unicodeScalars {
			switch scalar {
				case "\"": quoted += "\\\""
				case "\\": quoted += "\\\\"
				case "\n": quoted += "\\n"
				case "\r": quoted += "\\r"
				case "\t": quoted += "\\t"
				case _ where scalar.value < 0x20 || scalar.value == 0x7F:
					quoted += String(format: "\\u%04X", scalar.value)
				default: quoted.unicodeScalars.append(scalar)
			}
		}
		return quoted + "\""
	}
}
