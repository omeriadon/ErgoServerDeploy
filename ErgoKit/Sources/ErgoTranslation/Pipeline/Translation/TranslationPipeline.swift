//
//  TranslationPipeline.swift
//  Ergo
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoLogic
import Foundation

/// English → logic, step by step:
/// 1. Validate locally, so gibberish never reaches a model
/// 2. Gate: is it an argument, claims, or neither
/// 3. Breakdown: premises, conclusion, and up to six simple claims with descriptors
/// 4. Formalize, then compile with `LogicParser`, feeding errors back for another try
/// 5. Verify: read the logic back with `LogicEnglish` and ask whether it still means the same, feeding differences
///    back the same way, or to breakdown when the premises themselves are wrong, which formalize isn't allowed to change
///
/// Logic is only ever returned once it has compiled and been verified. Running out of tries is a failure, and the
/// differences come back as issues, since logic known to be wrong is worse than none.
///
/// `breakDown` runs only steps 1 to 3, for pasted arguments that become several statements.
///
/// On a canvas board every statement shares the board's letters. `descriptors` are what the board already calls
/// its letters (six, empty for a free slot): a claim that matches one keeps that letter, and new claims only
/// take free slots, so `P` in one statement is still `P` in the next.
public struct TranslationPipeline: Sendable {
	public let backend: any TranslationBackend
	public let letters: [String]

	/// Nil when the board names nothing, which gives every claim the next free letter in order
	public let descriptors: [String]?

	public init(backend: any TranslationBackend, letters: [String], descriptors: [String]? = nil) {
		self.backend = backend
		self.letters = letters
		self.descriptors = descriptors
	}

	/// Throws only when the backend can't be reached or the task is cancelled, everything else ends up in `issues`.
	/// `events` hears about each step as it happens.
	public func translate(
		_ english: String,
		events: @escaping @Sendable (TranslationEvent) async -> Void = { _ in }
	) async throws -> Translation {
		var result = Translation(english: english)
		let letters = LogicLetters.resolved(letters)
		var calls = Calls(backend: backend, events: events)

		func failure(_ message: String, notes: [String] = []) -> Translation {
			var failed = Translation(english: english)
			failed.issues = [TranslationIssue(severity: .error, message: message)]
				+ notes.map { TranslationIssue(severity: .warning, message: $0) }
			return failed
		}

		var understood: Understood
		switch try await understand(english, calls: &calls) {
			case let .failure(rejection):
				return failure(rejection.message)
			case let .success(found):
				understood = found
		}
		result.descriptors = understood.slots.descriptors
		await events(.foundClaims(premises: understood.breakdown.premises, conclusion: understood.conclusion ?? "", descriptors: result.descriptors))

		var previous: FormalizeStage.Output?
		var problems: [String] = []

		for attempt in stride(from: 1, through: backend.policy.attempts, by: 1) {
			let (breakdown, slots, conclusion) = (understood.breakdown, understood.slots, understood.conclusion)

			// Only problems that feed into another try are worth announcing
			func retry(_ rejected: [String]) async {
				problems = rejected
				if attempt < backend.policy.attempts {
					await events(.retrying(problems: rejected, attempt: attempt))
				}
			}

			let output = try await calls.run(
				FormalizeStage.self,
				.formalize,
				FormalizeStage.Input(
					english: english,
					premises: breakdown.premises,
					conclusion: conclusion,
					letters: zip(slots.slots, breakdown.claims).map { FormalizeStage.Input.Letter(letter: letters[$0], meaning: $1.meaning) },
					descriptors: descriptors.map { _ in
						slots.existing.indices.filter { !slots.existing[$0].isEmpty }.map { FormalizeStage.Input.Letter(letter: letters[$0], meaning: slots.existing[$0]) }
					},
					grammar: LogicGrammar.reference(letters: letters),
					grammarVersion: LogicGrammar.version,
					previous: previous,
					problems: problems
				)
			)
			previous = output

			let compiled = compile(
				output,
				premises: breakdown.premises.count,
				hasConclusion: conclusion != nil,
				letters: letters,
				allowing: descriptors == nil ? nil : Set(slots.slots.map { $0 + LogicLetters.slots.lowerBound })
			)
			guard let entries = compiled.entries else {
				await retry(compiled.problems)
				continue
			}

			// Keep the last version that compiled, even if a later try doesn't
			result.entries = entries
			result.issues = []
			await events(.drafted(entries: entries, attempt: attempt))

			guard backend.policy.verifies else { return result }

			let reading = LogicEnglish.text(for: LogicParser.parse(entries).argument, letters: letters, descriptors: result.descriptors)
			let verdict = try await calls.run(VerifyStage.self, .verify, VerifyStage.Input(english: english, reading: reading))
			if verdict.matches {
				return result
			}

			await retry(verdict.differences)

			// Formalize has to keep the premises it's given, so only breakdown can fix these
			guard verdict.structural, attempt < backend.policy.attempts else { continue }
			if case let .success(found) = try await split(english, gate: understood.gate, calls: &calls, previous: breakdown, problems: verdict.differences) {
				understood = found
				result.descriptors = found.slots.descriptors
				previous = nil
				problems = []
				await events(.foundClaims(premises: found.breakdown.premises, conclusion: found.conclusion ?? "", descriptors: result.descriptors))
			}
		}

		return failure("Expected logic that means the same as the English, found none in \(backend.policy.attempts) tries", notes: problems)
	}

	/// Each statement on its own line, then ∴ and the conclusion. Problems are worded for the model to fix.
	/// `allowed` limits which letter slots may appear, so a statement can't take a letter another claim on the board owns.
	func compile(
		_ output: FormalizeStage.Output,
		premises expectedPremises: Int,
		hasConclusion: Bool,
		letters: [String],
		allowing allowed: Set<Int>?
	) -> (entries: [LogicKeyboardEntry]?, problems: [String]) {
		let vocabulary = LogicInputVocabulary(letters: letters)
		var problems: [String] = []
		var statements: [[LogicKeyboardEntry]] = []

		if output.premises.count != expectedPremises {
			problems.append("Expected \(expectedPremises) premises, found \(output.premises.count)")
		}

		var labelled = output.premises.enumerated().map { ("Premise \($0.offset + 1)", $0.element) }
		if hasConclusion {
			labelled.append(("Conclusion", output.conclusion))
		}

		for (label, text) in labelled {
			let unknown = text.filter { !$0.isWhitespace && vocabulary.entry(for: $0) == nil }
			guard unknown.isEmpty else {
				problems.append("\(label) '\(text)': Unknown symbols '\(unknown)'")
				continue
			}

			let entries = text.compactMap { vocabulary.entry(for: $0) }
			if let allowed {
				let stray = entries.compactMap { entry -> String? in
					guard case let .variable(slot) = entry, !allowed.contains(slot) else { return nil }
					return LogicLetters.letter(for: slot, in: letters)
				}
				if !stray.isEmpty {
					let names = allowed.sorted().map { LogicLetters.letter(for: $0, in: letters) }.joined(separator: ", ")
					problems.append("\(label) '\(text)': Expected only the letters \(names), found '\(Set(stray).sorted().joined(separator: ", "))'")
					continue
				}
			}
			let parse = LogicParser.parse(entries)

			if let diagnostic = parse.diagnostics.first {
				problems.append("\(label) '\(text)': \(diagnostic.problem.message(letters: letters))")
			} else if parse.marker != nil || parse.argument.premises.count != 1 {
				problems.append("\(label) '\(text)': Expected exactly one statement")
			} else {
				statements.append(entries)
			}
		}

		guard problems.isEmpty else {
			return (nil, problems)
		}

		var entries: [LogicKeyboardEntry] = []
		for (index, statement) in statements.enumerated() {
			if index > 0 {
				entries.append(.delimiter("\n"))
			}
			if hasConclusion, index == statements.count - 1 {
				entries.append(.symbol("∴"))
			}
			entries += statement
		}

		return (entries, [])
	}
}

/// Which letter slot each claim gets. A claim whose descriptor matches one the board already has keeps that slot,
/// and the rest take free slots in order, so with nothing existing it's the claims in order, one letter each.
struct ClaimSlots {
	/// The board's descriptors going in, one per slot
	let existing: [String]

	/// The slot, from 0, of each claim in claim order
	let slots: [Int]

	/// How many new claims found no free slot. The claims don't fit while this isn't 0.
	let unplaced: Int

	/// The board's descriptors coming out: existing ones kept, each new claim's in its slot
	let descriptors: [String]

	init(claims: [BreakdownStage.Output.Claim], existing: [String]) {
		self.existing = existing
		var taken: Set<Int> = []
		var placed: [Int?] = claims.map { claim in
			let descriptor = LogicLetters.sanitizedDescriptor(claim.descriptor)
			guard !descriptor.isEmpty,
			      let slot = existing.indices.first(where: { !taken.contains($0) && existing[$0].caseInsensitiveCompare(descriptor) == .orderedSame })
			else {
				return nil
			}
			taken.insert(slot)
			return slot
		}

		var free = existing.indices.filter { existing[$0].isEmpty }.makeIterator()
		var unplaced = 0
		for index in placed.indices where placed[index] == nil {
			if let slot = free.next() {
				placed[index] = slot
			} else {
				unplaced += 1
			}
		}

		var descriptors = existing
		for (claim, slot) in zip(claims, placed) {
			if let slot, existing[slot].isEmpty {
				descriptors[slot] = LogicLetters.sanitizedDescriptor(claim.descriptor)
			}
		}
		slots = placed.compactMap(\.self)
		self.unplaced = unplaced
		self.descriptors = descriptors
	}
}
