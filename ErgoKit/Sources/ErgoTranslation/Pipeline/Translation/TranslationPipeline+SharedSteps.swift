//
//  TranslationPipeline+SharedSteps.swift
//  Ergo
//
//  Created by Adon Omeri on 8/11/2026.
//

import ErgoLogic
import Foundation

// MARK: - Shared steps

extension TranslationPipeline {
	/// Why the English can't go any further, worded for the user
	struct Rejection: Error {
		let message: String
	}

	/// What validating, the gate and breakdown found
	struct Understood {
		let gate: GateStage.Output
		let breakdown: BreakdownStage.Output
		let slots: ClaimSlots

		/// Nil when the text only makes claims
		var conclusion: String? {
			gate.kind == .argument && !breakdown.conclusion.isEmpty ? breakdown.conclusion : nil
		}
	}

	/// Every model call goes through here, so each one is announced and can be cancelled
	struct Calls {
		let backend: any TranslationBackend
		let events: @Sendable (TranslationEvent) async -> Void
		var attempts: [TranslationStep: Int] = [:]

		init(backend: any TranslationBackend, events: @escaping @Sendable (TranslationEvent) async -> Void) {
			self.backend = backend
			self.events = events
		}

		mutating func run<Stage: TranslationStage>(_ stage: Stage.Type, _ step: TranslationStep, _ input: Stage.Input) async throws -> Stage.Output {
			try Task.checkCancellation()
			attempts[step, default: 0] += 1
			await events(.started(step: step, attempt: attempts[step, default: 0]))
			return try await backend.run(stage, input)
		}
	}

	/// Steps 1 to 3, which both `translate` and `breakDown` start with
	func understand(_ english: String, calls: inout Calls) async throws -> Result<Understood, Rejection> {
		if let problem = EnglishValidator.problem(with: english) {
			return .failure(Rejection(message: problem))
		}

		let gate = try await calls.run(GateStage.self, .gate, GateStage.Input(english: english))
		guard gate.kind != .neither else {
			return .failure(Rejection(message: gate.reason.isEmpty ? "Expected an argument or a claim" : gate.reason))
		}
		return try await split(english, gate: gate, calls: &calls)
	}

	/// Step 3, and again with what was wrong when verifying finds the premises themselves are off
	func split(
		_ english: String,
		gate: GateStage.Output,
		calls: inout Calls,
		previous: BreakdownStage.Output? = nil,
		problems: [String]? = nil
	) async throws -> Result<Understood, Rejection> {
		let own = Self.existing(descriptors)
		let breakdown = try await calls.run(
			BreakdownStage.self,
			.breakdown,
			BreakdownStage.Input(
				english: english,
				maximumClaims: LogicLetters.slots.count,
				descriptorWordLimit: LogicLetters.descriptorWordLimit,
				descriptors: descriptors == nil ? nil : own.filter { !$0.isEmpty },
				previous: previous,
				problems: problems
			)
		)
		guard !breakdown.claims.isEmpty else {
			return .failure(Rejection(message: "Expected at least one claim"))
		}
		guard breakdown.claims.count <= LogicLetters.slots.count else {
			return .failure(Rejection(message: "Expected at most \(LogicLetters.slots.count) separate claims, found \(breakdown.claims.count)"))
		}

		let slots = ClaimSlots(claims: breakdown.claims, existing: own)
		guard slots.unplaced == 0 else {
			let free = slots.existing.count(where: \.isEmpty)
			let noun = free == 1 ? "claim" : "claims"
			return .failure(Rejection(message: "Expected at most \(free) new \(noun), found \(free + slots.unplaced), the board's other letters are taken"))
		}
		return .success(Understood(gate: gate, breakdown: breakdown, slots: slots))
	}

	/// The board's descriptors as six sanitised strings, empty for a free slot
	static func existing(_ descriptors: [String]?) -> [String] {
		LogicLetters.slots.map { LogicLetters.descriptor(for: $0, in: descriptors ?? []) }
	}
}
