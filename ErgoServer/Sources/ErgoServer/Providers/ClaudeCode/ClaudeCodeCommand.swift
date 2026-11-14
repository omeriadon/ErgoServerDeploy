//
//  ClaudeCodeCommand.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoProtocol
import Foundation

/// One `claude -p` call: no tools, no settings, no MCP and no session left behind, so all the model can do is answer
struct ClaudeCodeCommand {
	let executable: String
	let choice: StageModels.Choice

	/// `Stage.outputSchema.encoded()`
	let schema: String
	let instructions: URL
	let credential: ProviderCredential
	let run: RunDirectory

	var arguments: [String] {
		var arguments = [
			"-p",
			"--output-format", "json",
			"--json-schema", schema,
		]
		if let model = choice.model {
			arguments += ["--model", model]
		}
		if let effort = choice.effort {
			arguments += ["--effort", effort]
		}
		arguments += [
			"--tools", "",
			"--system-prompt-file", instructions.path,
			"--setting-sources", "",
			"--strict-mcp-config",
			"--no-session-persistence",
			// Structured output takes two turns, the rest is headroom
			"--max-turns", "4",
		]
		return arguments
	}

	/// Built from nothing, so none of the server's environment reaches the CLI
	var environment: [String: String] {
		var environment = [
			"PATH": Self.path(for: executable),
			"HOME": run.home.path,
			"TMPDIR": run.temporary.path,
			"LANG": "C.UTF-8",
			"DISABLE_AUTOUPDATER": "1",
		]

		// Exactly one, since an API key would quietly win over the subscription
		switch credential.kind {
			case .subscription:
				environment["CLAUDE_CODE_OAUTH_TOKEN"] = credential.secret.value
			case .apiKey:
				environment["ANTHROPIC_API_KEY"] = credential.secret.value
		}
		return environment
	}

	func command(prompt: String) -> ProcessRunner.Command {
		ProcessRunner.Command(executable: executable, arguments: arguments, environment: environment, directory: run.work, input: prompt)
	}

	/// The CLI's own directory first, in case it's a script that needs its interpreter beside it
	static func path(for executable: String) -> String {
		let directory = URL(filePath: executable).deletingLastPathComponent().path
		return ([directory] + ["/usr/local/bin", "/usr/bin", "/bin"])
			.reduce(into: [String]()) {
				if !$0.contains($1) {
					$0.append($1)
				}
			}
			.joined(separator: ":")
	}
}
