//
//  TranslationPipeline+BreakDown.swift
//  Ergo
//
//  Created by Adon Omeri on 8/11/2026.
//

import ErgoLogic
import Foundation

// MARK: - Breaking down

public extension TranslationPipeline {
	/// Steps 1 to 3 only: what a pasted argument is made of, for the app to build statements and links from.
	/// Throws only when the backend can't be reached or the task is cancelled. English that can't be broken down
	/// comes back with an error in `issues`, like `translate`.
	func breakDown(
		_ english: String,
		events: @escaping @Sendable (TranslationEvent) async -> Void = { _ in }
	) async throws -> ArgumentBreakdown {
		var calls = Calls(backend: backend, events: events)
		let own = TranslationPipeline.existing(descriptors)

		switch try await understand(english, calls: &calls) {
			case let .failure(rejection):
				return ArgumentBreakdown(
					kind: .neither,
					descriptors: own,
					issues: [TranslationIssue(severity: .error, message: rejection.message)]
				)

			case let .success(found):
				let conclusion = found.gate.kind == .argument ? found.breakdown.conclusion : ""
				await events(.foundClaims(premises: found.breakdown.premises, conclusion: conclusion, descriptors: found.slots.descriptors))
				return ArgumentBreakdown(
					kind: found.gate.kind,
					premises: found.breakdown.premises,
					conclusion: conclusion,
					claims: found.breakdown.claims,
					descriptors: found.slots.descriptors
				)
		}
	}
}
