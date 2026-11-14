//
//  TitleStage.swift
//  ErgoKit
//
//  Created by Adon Omeri on 9/11/2026.
//

import Foundation

/// Names a new Ask chat from its first question and answer. It only makes a title, never answers.
public enum TitleStage: TranslationStage {
	public static let name = "title"

	public struct Input: Codable, Sendable {
		public let question: String
		public let answer: String

		public init(question: String, answer: String) {
			self.question = question
			self.answer = answer
		}
	}

	public struct Output: Codable, Sendable {
		public let title: String

		public init(title: String) {
			self.title = title
		}
	}

	public static let outputSchema = JSONSchema.object([
		.init("title", .string(description: "A short title for the chat, a few words, never a sentence answering the question")),
	])
}
