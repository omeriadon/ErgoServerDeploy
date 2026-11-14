//
//  StageModels.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoProtocol
import ErgoTranslation
import Foundation

/// Which model answers each stage for each provider. Users only pick the provider, so the server decides.
struct StageModels: Codable, Sendable, Hashable {
	struct Choice: Codable, Sendable, Hashable {
		/// Nil leaves the CLI's own default
		var model: String?
		var effort: String?
	}

	/// Keyed by stage name
	var claude: [String: Choice]
	var codex: [String: Choice]

	var attempts: Int
	var verifies: Bool

	var policy: TranslationPolicy {
		TranslationPolicy(attempts: attempts, verifies: verifies)
	}

	/// OpenRouter has one model for every stage, `ServerConfig.openRouter`'s, so it has no cells here
	func choice(for provider: Provider, stage: String) -> Choice {
		let choices: [String: Choice] = switch provider {
			case .claude: claude
			case .codex: codex
			case .openrouter: [:]
		}
		return choices[stage] ?? Choice()
	}

	static let stages = [GateStage.name, BreakdownStage.name, FormalizeStage.name, VerifyStage.name]

	/// Ask isn't a translation stage, but it picks its model and prompt the same way. It writes for people, and reads
	/// the library first, so it gets a stronger model than the stages' small jobs.
	static let ask = "ask"

	/// Board analysis runs like Ask, with `ask`'s models, but has instructions of its own
	static let analyse = "analyse"

	/// Names a new chat once its first answer is done. It's a small job like the stages', so it gets their model.
	static let title = TitleStage.name

	static let defaults = StageModels(
		claude: Dictionary(uniqueKeysWithValues: stages.map { ($0, Choice(model: "claude-haiku-5-5", effort: "medium")) })
			.merging([ask: Choice(model: "claude-sonnet-5-5", effort: "medium"), title: Choice(model: "claude-haiku-5-5", effort: "medium")]) { _, new in new },
		codex: Dictionary(uniqueKeysWithValues: (stages + [ask, title]).map { ($0, Choice(model: "gpt-6-luna", effort: "medium")) }),
		attempts: 3,
		verifies: true
	)

	// MARK: - Overrides

	/// The same model or effort on every stage, for whichever of these is set
	func overriding(claudeModel: String?, codexModel: String?, effort: String?) -> StageModels {
		var models = self
		models.claude = claude.mapValues { Choice(model: claudeModel ?? $0.model, effort: effort ?? $0.effort) }
		models.codex = codex.mapValues { Choice(model: codexModel ?? $0.model, effort: effort ?? $0.effort) }
		return models
	}

	/// Every field optional, and a cell replaces the default cell whole
	private struct Overrides: Decodable {
		var claude: [String: Choice]?
		var codex: [String: Choice]?
		var attempts: Int?
		var verifies: Bool?
	}

	static func load(from file: URL) throws -> StageModels {
		let data: Data
		do {
			data = try Data(contentsOf: file)
		} catch {
			throw ServerConfig.Problem(description: "ERGO_MODELS_FILE: Couldn't read '\(file.path)'")
		}
		return try decode(data)
	}

	static func decode(_ data: Data) throws -> StageModels {
		let overrides: Overrides
		do {
			overrides = try JSONDecoder().decode(Overrides.self, from: data)
		} catch {
			throw ServerConfig.Problem(description: "ERGO_MODELS_FILE: Expected JSON with 'claude', 'codex', 'attempts' or 'verifies'")
		}
		return try defaults.applying(overrides)
	}

	private func applying(_ overrides: Overrides) throws -> StageModels {
		var models = self
		for (stage, _) in (overrides.claude ?? [:]).merging(overrides.codex ?? [:], uniquingKeysWith: { first, _ in first }) {
			guard Self.stages.contains(stage) || stage == Self.ask || stage == Self.title else {
				throw ServerConfig.Problem(description: "ERGO_MODELS_FILE: Unknown stage '\(stage)', expected one of \(Self.stages.map { "'\($0)'" }.joined(separator: ", "))")
			}
		}

		models.claude.merge(overrides.claude ?? [:]) { _, override in override }
		models.codex.merge(overrides.codex ?? [:]) { _, override in override }
		models.attempts = overrides.attempts ?? attempts
		models.verifies = overrides.verifies ?? verifies

		guard models.attempts > 0 else {
			throw ServerConfig.Problem(description: "ERGO_MODELS_FILE: Expected at least 1 attempt, found \(models.attempts)")
		}
		return models
	}
}
