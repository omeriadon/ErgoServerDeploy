//
//  CLIInstaller.swift
//  ErgoServer
//
//  Created by Adon Omeri on 6/11/2026.
//

import Foundation
import Logging
import Subprocess

/// At launch, installs either CLI that doesn't run, at the pinned version, when `ServerConfig.cliInstall` is set.
/// It asks `--version` rather than looking for the file, since a failed npm postinstall leaves a placeholder behind.
/// One that can't be installed becomes nil, so the app hears it isn't installed, and the server still starts.
struct CLIInstaller {
	let install: ServerConfig.CLIInstall
	let runsDirectory: URL
	let runner: ProcessRunner
	let logger: Logger

	static func ensure(_ config: inout ServerConfig, logger: Logger) async {
		guard let install = config.cliInstall else { return }

		// No prefix, so npm runs as the server, the only user that can write to the install directory
		let runner = ProcessRunner(maxProcesses: 1, timeout: .seconds(5 * 60))
		let installer = CLIInstaller(install: install, runsDirectory: config.runsDirectory, runner: runner, logger: logger)

		config.claudePath = await installer.resolve(
			config.claudePath,
			binary: "claude",
			package: "@anthropic-ai/claude-code@\(install.claudeCodeVersion)"
		)
		config.codexPath = await installer.resolve(
			config.codexPath,
			binary: "codex",
			package: "@openai/codex@\(install.codexVersion)"
		)
	}

	/// The path to use, installing if neither the configured one nor an earlier install runs
	private func resolve(_ configured: String?, binary: String, package: String) async -> String? {
		if await runs(configured) {
			return configured
		}

		let installed = install.directory.appending(path: "bin/\(binary)").path
		if await runs(installed) {
			return installed
		}

		logger.warning("Installing a CLI that doesn't run", metadata: ["package": "\(package)"])
		do {
			let finished = try await RunDirectory.with(in: runsDirectory) { run in
				try await runner.run(
					command(
						install.npmPath,
						arguments: ["install", "--global", "--prefix", install.directory.path, "--no-audit", "--no-fund", package],
						in: run
					),
					in: run
				)
			}
			guard finished.status == .exited(0) else {
				logger.error("Couldn't install a CLI", metadata: ["package": "\(package)", "output": "\(finished.errorOutput)"])
				return nil
			}
		} catch {
			logger.error("Couldn't install a CLI", metadata: ["package": "\(package)", "error": "\(String(reflecting: error))"])
			return nil
		}

		guard await runs(installed) else {
			logger.error("Installed a CLI that doesn't run", metadata: ["package": "\(package)"])
			return nil
		}
		logger.notice("Installed a CLI", metadata: ["package": "\(package)"])
		return installed
	}

	private func runs(_ path: String?) async -> Bool {
		guard let path, FileManager.default.isExecutableFile(atPath: path) else { return false }

		let finished = try? await RunDirectory.with(in: runsDirectory) { run in
			try await runner.run(command(path, arguments: ["--version"], in: run), in: run)
		}
		return finished?.status == .exited(0)
	}

	private func command(_ executable: String, arguments: [String], in run: RunDirectory) -> ProcessRunner.Command {
		ProcessRunner.Command(
			executable: executable,
			arguments: arguments,
			environment: [
				"PATH": ClaudeCodeCommand.path(for: executable),
				"HOME": run.home.path,
				"TMPDIR": run.temporary.path,
				"LANG": "C.UTF-8",
			],
			directory: run.work
		)
	}
}
