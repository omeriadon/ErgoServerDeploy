//
//  PracticeCard.swift
//  ErgoKit
//
//  Created by Adon Omeri on 14/11/2026.
//

import Foundation

/// One thing to practise. Its choices are drawn when it's asked (`PracticeQuestion`), so the same card reads a little
/// differently each time. Everything on it comes from the library or the course as written, never made up.
public struct PracticeCard: Identifiable, Hashable, Sendable {
	public enum Kind: String, Codable, Sendable, CaseIterable {
		/// An example or a description with the name hidden: which entry is it?
		case identify
		/// A name: which description is it?
		case define
		/// A course exercise: valid or invalid?
		case validity
	}

	public enum Source: Hashable, Sendable {
		/// A library entry, as its category (`"fallacies"`) and id
		case library(category: String, id: String)
		/// A lesson of the Logic tab's course
		case lesson(id: String)
	}

	/// What progress is saved under, like `fallacies/straw-man/identify`. Never change how it's made: saved progress
	/// would be lost.
	public let id: String
	public let kind: Kind

	/// A library category, or `PracticeCard.courseTopic`
	public let topic: String
	public let source: Source

	/// The entry's name, the lesson's title
	public let title: String

	/// The ways the card can be asked, one picked each time. Library cards keep the name hidden in every one.
	public let prompts: [String]

	/// Shown under the prompt, like a course exercise's English reading
	public let detail: String?

	public let answer: String

	/// Set when the choices never change, like Valid and Invalid. They're shown in this order.
	public let fixedChoices: [String]?

	/// Shown once it's answered
	public let explanation: String?

	public static let courseTopic = "course"

	public init(
		id: String,
		kind: Kind,
		topic: String,
		source: Source,
		title: String,
		prompts: [String],
		detail: String? = nil,
		answer: String,
		fixedChoices: [String]? = nil,
		explanation: String? = nil
	) {
		self.id = id
		self.kind = kind
		self.topic = topic
		self.source = source
		self.title = title
		self.prompts = prompts
		self.detail = detail
		self.answer = answer
		self.fixedChoices = fixedChoices
		self.explanation = explanation
	}

	/// A course exercise. The choices are always Valid then Invalid.
	public static func exercise(
		lessonID: String,
		lessonTitle: String,
		argument: String,
		reading: String,
		isValid: Bool,
		explanation: String
	) -> PracticeCard {
		PracticeCard(
			id: "\(courseTopic)/\(lessonID)/\(argument)",
			kind: .validity,
			topic: courseTopic,
			source: .lesson(id: lessonID),
			title: lessonTitle,
			prompts: [argument],
			detail: reading,
			answer: isValid ? validChoice : invalidChoice,
			fixedChoices: [validChoice, invalidChoice],
			explanation: explanation
		)
	}

	public static let validChoice = "Valid"
	public static let invalidChoice = "Invalid"
}

/// A card as it's asked this time
public struct PracticeQuestion: Hashable, Sendable {
	public let card: PracticeCard
	public let prompt: String
	public let choices: [String]
	public let correctIndex: Int

	public init(card: PracticeCard, prompt: String, choices: [String], correctIndex: Int) {
		self.card = card
		self.prompt = prompt
		self.choices = choices
		self.correctIndex = correctIndex
	}

	public var answer: String {
		choices[correctIndex]
	}
}
