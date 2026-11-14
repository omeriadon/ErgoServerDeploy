//
//  TranslationStage.swift
//  Ergo
//
//  Created by Adon Omeri on 5/11/2026.
//

import Foundation

/// One model call in English → logic translation. Every backend runs the same stages:
/// it gets `Input` as JSON and answers with `Output` as JSON, shaped by `outputSchema`.
/// Outputs have no optional fields, an empty string or array means none.
public protocol TranslationStage {
	associatedtype Input: Codable & Sendable
	associatedtype Output: Codable & Sendable

	/// What the server routes on, so never rename one
	static var name: String { get }

	/// Handed to the model as its structured-output format
	static var outputSchema: JSONSchema { get }
}
