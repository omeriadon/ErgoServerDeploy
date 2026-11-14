//
//  LogicCourse.swift
//  ErgoKit
//
//  Created by Adon Omeri on 10/11/2026.
//

import Foundation

/// Is this argument valid? A test checks every answer here against `LogicChecker`.
public struct LogicExercise: Identifiable, Hashable, Sendable {
	/// Keyboard text in the default letters, with spaces for reading
	public let argument: String

	/// The same thing in English, so the shape has something to stand on
	public let reading: String
	public let isValid: Bool

	/// Why, for after it's been answered
	public let explanation: String

	public var id: String {
		argument
	}

	/// What the checker reads
	public var entries: [LogicKeyboardEntry] {
		LogicInputVocabulary(letters: LogicLetters.defaults).entries(in: argument.replacingOccurrences(of: " ", with: ""))
	}
}

public struct LogicLesson: Identifiable, Hashable, Sendable {
	public let id: String
	public let title: String
	public let summary: String
	public let paragraphs: [String]
	public let exercises: [LogicExercise]
}

/// A short course in the logic the Logic tab checks. The first lessons are free.
public enum LogicCourse {
	public static let freeLessons = 2

	public static func isFree(_ lesson: LogicLesson) -> Bool {
		lessons.prefix(freeLessons).contains(lesson)
	}

	public static func lesson(_ id: String) -> LogicLesson? {
		lessons.first { $0.id == id }
	}

	public static let lessons: [LogicLesson] = [
		LogicLesson(
			id: "arguments",
			title: "What an Argument Is",
			summary: "Premises, a conclusion, and what valid means.",
			paragraphs: [
				"An argument gives reasons for a claim. The reasons are its premises, and the claim is its conclusion. In logic, letters stand for whole claims, and ∴ means \"therefore\".",
				"An argument is valid when it's impossible for all its premises to be true and its conclusion false. Valid is about the shape: if the premises were true, the conclusion would have to be. It doesn't say the premises are true.",
				"So to test an argument, try to imagine the premises true and the conclusion false. If you can, it's invalid.",
			],
			exercises: [
				LogicExercise(argument: "X → Y, X ∴ Y", reading: "If it rained, the ground is wet. It rained. So the ground is wet.", isValid: true, explanation: "If the first two are true there's no room for the ground to be dry. This shape is called modus ponens."),
				LogicExercise(argument: "X → Y, Y ∴ X", reading: "If it rained, the ground is wet. The ground is wet. So it rained.", isValid: false, explanation: "A sprinkler makes both premises true and the conclusion false. This is affirming the consequent."),
				LogicExercise(argument: "X, Y ∴ X ∧ Y", reading: "It's raining. It's cold. So it's raining and cold.", isValid: true, explanation: "Saying both together adds nothing that the two premises didn't already say."),
			]
		),
		LogicLesson(
			id: "connectives",
			title: "And, Or, Not",
			summary: "The words that build bigger claims out of smaller ones.",
			paragraphs: [
				"X ∧ Y (\"and\") is true only when both are. X ∨ Y (\"or\") is true when at least one is, including both. ¬X (\"not\") is true exactly when X is false.",
				"Logic's \"or\" is the inclusive one. \"Tea or coffee?\" often means one but not both, and an argument can go wrong by sliding between the two.",
			],
			exercises: [
				LogicExercise(argument: "X ∧ Y ∴ X", reading: "It's raining and cold. So it's raining.", isValid: true, explanation: "An \"and\" can only be true if each half is."),
				LogicExercise(argument: "X ∨ Y ∴ X", reading: "She's in Paris or Rome. So she's in Paris.", isValid: false, explanation: "She could be in Rome, which keeps the premise true and makes the conclusion false."),
				LogicExercise(argument: "X ∨ Y, ¬X ∴ Y", reading: "She's in Paris or Rome. She isn't in Paris. So she's in Rome.", isValid: true, explanation: "Ruling out one side of an \"or\" leaves the other. This is disjunctive syllogism."),
			]
		),
		LogicLesson(
			id: "conditionals",
			title: "If, Then",
			summary: "The arrow, and the two mistakes people make with it.",
			paragraphs: [
				"X → Y says: if X, then Y. It only rules out one situation, X true with Y false. It doesn't say X causes Y, and it doesn't say anything when X is false.",
				"Two moves are safe: from X get Y, and from not-Y get not-X. Two look the same and aren't: from Y get X, and from not-X get not-Y.",
			],
			exercises: [
				LogicExercise(argument: "X → Y, ¬Y ∴ ¬X", reading: "If it rained, the ground is wet. The ground isn't wet. So it didn't rain.", isValid: true, explanation: "Had it rained, the ground would be wet. It isn't, so it didn't. This is modus tollens."),
				LogicExercise(argument: "X → Y, ¬X ∴ ¬Y", reading: "If it rained, the ground is wet. It didn't rain. So the ground isn't wet.", isValid: false, explanation: "The premise says nothing about what happens without rain. This is denying the antecedent."),
				LogicExercise(argument: "X → Y, Y → Z ∴ X → Z", reading: "If I'm late, I miss the bus. If I miss the bus, I walk. So if I'm late, I walk.", isValid: true, explanation: "The arrows chain together. This is hypothetical syllogism."),
			]
		),
		LogicLesson(
			id: "valid-and-sound",
			title: "Valid Isn't True",
			summary: "Why a valid argument can still be a bad one.",
			paragraphs: [
				"An argument is sound when it's valid and its premises really are true. Validity is what logic can check. Whether the premises are true usually isn't.",
				"Some valid arguments are useless. An argument whose conclusion is one of its premises is valid and proves nothing, and premises that contradict each other make everything follow, since they can never all be true.",
			],
			exercises: [
				LogicExercise(argument: "X ∴ X", reading: "God exists. So God exists.", isValid: true, explanation: "It's valid, and circular. It can't persuade anyone who doesn't already agree."),
				LogicExercise(argument: "X, ¬X ∴ Y", reading: "It's raining. It isn't raining. So the moon is cheese.", isValid: true, explanation: "The premises can never both be true, so there's no case where they're true and the conclusion false. Valid, and worthless."),
				LogicExercise(argument: "X → Y ∴ Y → X", reading: "If you're a surgeon, you went to medical school. So if you went to medical school, you're a surgeon.", isValid: false, explanation: "A GP went to medical school and isn't a surgeon. An arrow doesn't turn around."),
			]
		),
		LogicLesson(
			id: "only-if-unless",
			title: "Only If, Unless",
			summary: "Putting tricky English into the right shape.",
			paragraphs: [
				"\"X only if Y\" means X → Y. Being a citizen is required, so you vote only if you're a citizen: if you vote, you're a citizen. The word \"only\" is what flips it from how it sounds.",
				"\"X unless Y\" means ¬Y → X: if not Y, then X. X ↔ Y (\"if and only if\") says the two stand or fall together.",
				"An arrow always equals its contrapositive: X → Y says the same as ¬Y → ¬X. It doesn't equal ¬X → ¬Y.",
			],
			exercises: [
				LogicExercise(argument: "X → Y ∴ ¬Y → ¬X", reading: "You vote only if you're a citizen. So if you're not a citizen, you don't vote.", isValid: true, explanation: "That's the contrapositive, which says the same thing in other words."),
				LogicExercise(argument: "X → Y ∴ ¬X → ¬Y", reading: "You vote only if you're a citizen. So if you don't vote, you're not a citizen.", isValid: false, explanation: "Plenty of citizens stay home."),
				LogicExercise(argument: "¬X → Y, ¬Y ∴ X", reading: "Unless it's raining, we'll walk. We won't walk. So it's raining.", isValid: true, explanation: "Modus tollens again, with a \"not\" already inside."),
				LogicExercise(argument: "X ↔ Y, Y ∴ X", reading: "The light is on if and only if the switch is up. The switch is up. So the light is on.", isValid: true, explanation: "Unlike a one-way arrow, a two-way one lets you go back."),
			]
		),
		LogicLesson(
			id: "all-and-some",
			title: "All and Some",
			summary: "Claims about every thing, and about at least one.",
			paragraphs: [
				"∀X P(X) says everything is P, and ∃X P(X) says at least one thing is. Here P(X) is a property of X, and ∀X(P(X) → Q(X)) is how logic says \"every P is a Q\".",
				"\"Some\" doesn't carry to \"all\", and \"every P is a Q\" doesn't turn around. These are the same mistakes as before, in a new place.",
			],
			exercises: [
				LogicExercise(argument: "∀X(P(X) → Q(X)), P(Y) ∴ Q(Y)", reading: "Every human is mortal. Socrates is human. So Socrates is mortal.", isValid: true, explanation: "What's true of every P is true of this one."),
				LogicExercise(argument: "∀X(P(X) → Q(X)) ∴ ∀X(Q(X) → P(X))", reading: "Every human is mortal. So every mortal is human.", isValid: false, explanation: "Dogs are mortal too."),
				LogicExercise(argument: "∃X P(X) ∴ ∀X P(X)", reading: "Some swans are black. So all swans are black.", isValid: false, explanation: "One case can't speak for every case."),
			]
		),
	]
}
