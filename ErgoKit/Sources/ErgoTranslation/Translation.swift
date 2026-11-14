//
//  Translation.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoLogic
import Foundation

// Both are saved on boards as synthesized Codable, so never rename a case or stored property

public struct TranslationIssue: Codable, Hashable, Sendable {
	public enum Severity: String, Codable, Sendable {
		case error, warning
	}

	public let severity: Severity
	public let message: String

	public init(severity: Severity, message: String) {
		self.severity = severity
		self.message = message
	}
}

/// What came out of translating some English, kept on the board
public struct Translation: Codable, Hashable, Sendable {
	/// The English this came from, so the board can tell when the logic is out of date
	public let english: String

	/// Empty when it couldn't be translated
	public var entries: [LogicKeyboardEntry] = []

	/// One per letter slot, from the claims the model found
	public var descriptors = LogicLetters.emptyDescriptors

	public var issues: [TranslationIssue] = []

	public init(
		english: String,
		entries: [LogicKeyboardEntry] = [],
		descriptors: [String] = LogicLetters.emptyDescriptors,
		issues: [TranslationIssue] = []
	) {
		self.english = english
		self.entries = entries
		self.descriptors = descriptors
		self.issues = issues
	}
}
