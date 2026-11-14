//
//  ClaudeCodeAskCommand.swift
//  ErgoServer
//
//  Created by Adon Omeri on 6/11/2026.
//

import ErgoAsk
import ErgoProtocol
import Foundation

/// One `claude -p` call for Ask: streaming, with none of Claude Code's own tools and only Ergo's over MCP
struct ClaudeCodeAskCommand {
	let executable: String
	let choice: StageModels.Choice
	let instructions: URL
	let toolConfig: URL
	let credential: ProviderCredential
	let run: RunDirectory

	/// What it may call, without the prefix
	var toolNames = AskTools.names

	/// How many rounds of tool calls it may make
	var maxTurns = Self.maxTurns

	/// A few rounds of looking things up, then the answer
	static let maxTurns = 12

	static func toolConfig(url: String) throws -> String {
		let config = ["mcpServers": ["ergo": ["type": "http", "url": url]]]
		return try String(decoding: JSONEncoder().encode(config), as: UTF8.self)
	}

	var arguments: [String] {
		var arguments = [
			"-p",
			"--output-format", "stream-json",
			"--verbose",
			"--include-partial-messages",
		]
		if let model = choice.model {
			arguments += ["--model", model]
		}
		if let effort = choice.effort {
			arguments += ["--effort", effort]
		}
		arguments += [
			"--tools", "",
			"--mcp-config", toolConfig.path,
			"--strict-mcp-config",
			"--allowedTools", toolNames.map { "mcp__ergo__\($0)" }.joined(separator: ","),
			"--system-prompt-file", instructions.path,
			"--setting-sources", "",
			"--no-session-persistence",
			"--max-turns", "\(maxTurns)",
		]
		return arguments
	}

	func command(prompt: String) -> ProcessRunner.Command {
		let environment = ClaudeCodeCommand(executable: executable, choice: choice, schema: "", instructions: instructions, credential: credential, run: run).environment
		return ProcessRunner.Command(executable: executable, arguments: arguments, environment: environment, directory: run.work, input: prompt)
	}
}
