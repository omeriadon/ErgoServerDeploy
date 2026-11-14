//
//  TranslationBackend.swift
//  Ergo
//
//  Created by Adon Omeri on 5/11/2026.
//

import Foundation

/// Something that can answer a `TranslationStage`, like the server running a provider's CLI.
/// The pipeline doesn't care which.
public protocol TranslationBackend: Sendable {
	/// How many tries a weaker or stronger model needs
	var policy: TranslationPolicy { get }

	func run<Stage: TranslationStage>(_ stage: Stage.Type, _ input: Stage.Input) async throws -> Stage.Output
}

public struct TranslationPolicy: Sendable {
	/// Formalize calls before giving up, counting retries for compile errors and for differences in meaning
	public var attempts = 3

	/// Whether another call checks the logic still means what the English said
	public var verifies = true

	public init(attempts: Int = 3, verifies: Bool = true) {
		self.attempts = attempts
		self.verifies = verifies
	}
}
