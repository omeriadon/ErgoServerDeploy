//
//  TranslationPipelineTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoLogic
import ErgoTranslation
import Testing

/// Local validation, compile and meaning retries, the events along the way, and the JSON contract
struct TranslationPipelineTests {
	let letters = LogicLetters.defaults
	let vocabulary = LogicInputVocabulary(letters: LogicLetters.defaults)

	let english = "If it rains, the ground gets wet. It rained, so the ground is wet."
	let gate = #"{"kind": "argument", "reason": ""}"#
	let breakdown = #"{"premises": ["If it rains, the ground gets wet", "It rained"], "conclusion": "the ground is wet", "claims": [{"meaning": "It rains", "descriptor": "it rains"}, {"meaning": "The ground is wet", "descriptor": "the ground is wet"}]}"#
	let good = #"{"premises": ["X → Y", "X"], "conclusion": "Y"}"#
	let matches = #"{"matches": true, "differences": []}"#
	let differs = #"{"matches": false, "differences": ["Reading says rains, original says rained"]}"#

	let descriptors = ["it rains", "the ground is wet", "", "", "", ""]

	func translate(_ backend: ScriptedBackend, _ text: String? = nil, events: EventLog = EventLog()) async throws -> Translation {
		try await TranslationPipeline(backend: backend, letters: letters).translate(text ?? english) { events.record($0) }
	}

	// MARK: - Before any formalizing

	@Test func gibberishNeverReachesTheBackend() async throws {
		let quiet = ScriptedBackend([:])
		let events = EventLog()
		let gibberish = try await translate(quiet, "→∧¬ ∨∨ ()", events: events)

		#expect(gibberish.entries.isEmpty)
		#expect(gibberish.issues.first?.severity == .error)
		#expect(quiet.requests.isEmpty)
		#expect(events.all.isEmpty)
	}

	@Test func gateReasonBecomesTheError() async throws {
		let events = EventLog()
		let backend = ScriptedBackend(["gate": [#"{"kind": "neither", "reason": "Expected claims, found a question"}"#]])
		let notLogic = try await translate(backend, "Is it going to rain today or not?", events: events)

		#expect(notLogic.issues == [TranslationIssue(severity: .error, message: "Expected claims, found a question")])
		#expect(events.all == [.started(step: .gate, attempt: 1)])
	}

	// MARK: - Compiling

	@Test func compilerErrorsGoBackForAnotherTry() async throws {
		let retry = ScriptedBackend([
			"gate": [gate], "breakdown": [breakdown], "verify": [matches],
			"formalize": [#"{"premises": ["X →", "X"], "conclusion": "Y"}"#, good],
		])
		let events = EventLog()
		let retried = try await translate(retry, events: events)

		#expect(retry.count("formalize") == 2)
		#expect(retry.lastInput("formalize").contains("Expected statement after '→'"))
		#expect(retried.entries == vocabulary.entries(in: "X→Y\nX\n∴Y"))
		#expect(retried.descriptors == descriptors)
		#expect(retried.issues.isEmpty)
		#expect(LogicChecker.analyze(retried.entries).verdict == .valid)

		#expect(events.all == [
			.started(step: .gate, attempt: 1),
			.started(step: .breakdown, attempt: 1),
			.foundClaims(premises: ["If it rains, the ground gets wet", "It rained"], conclusion: "the ground is wet", descriptors: descriptors),
			.started(step: .formalize, attempt: 1),
			.retrying(problems: ["Premise 1 'X →': Expected statement after '→'"], attempt: 1),
			.started(step: .formalize, attempt: 2),
			.drafted(entries: vocabulary.entries(in: "X→Y\nX\n∴Y"), attempt: 2),
			.started(step: .verify, attempt: 1),
		])
	}

	@Test func unknownSymbolsAreCompilerErrors() async throws {
		let symbols = ScriptedBackend([
			"gate": [gate], "breakdown": [breakdown], "verify": [matches],
			"formalize": [#"{"premises": ["X & Y", "X"], "conclusion": "Y"}"#, good],
		])
		_ = try await translate(symbols)
		#expect(symbols.lastInput("formalize").contains("Unknown symbols '&'"))
	}

	@Test func wrongNumberOfPremises() async throws {
		let count = ScriptedBackend([
			"gate": [gate], "breakdown": [breakdown], "verify": [matches],
			"formalize": [#"{"premises": ["X → Y"], "conclusion": "Y"}"#, good],
		])
		_ = try await translate(count)
		#expect(count.lastInput("formalize").contains("Expected 2 premises, found 1"))
	}

	@Test func givesUpAfterThePolicysAttempts() async throws {
		let broken = ScriptedBackend(["gate": [gate], "breakdown": [breakdown], "formalize": [#"{"premises": ["(", "X"], "conclusion": "Y"}"#]])
		let events = EventLog()
		let gaveUp = try await translate(broken, events: events)

		#expect(broken.count("formalize") == 3)
		#expect(gaveUp.entries.isEmpty)
		#expect(gaveUp.issues.first == TranslationIssue(severity: .error, message: "Expected logic that means the same as the English, found none in 3 tries"))

		let problems = ["Premise 1 '(': Expected statement inside brackets"]
		#expect(events.all.dropFirst(3) == [
			.started(step: .formalize, attempt: 1),
			.retrying(problems: problems, attempt: 1),
			.started(step: .formalize, attempt: 2),
			.retrying(problems: problems, attempt: 2),
			.started(step: .formalize, attempt: 3),
		], "No retrying after the last attempt")
	}

	// MARK: - Verifying

	@Test func differencesInMeaningGoBackLikeCompilerErrors() async throws {
		let reworded = ScriptedBackend(["gate": [gate], "breakdown": [breakdown], "formalize": [good], "verify": [differs, matches]])
		let events = EventLog()
		let fixed = try await translate(reworded, events: events)

		#expect(reworded.count("formalize") == 2)
		#expect(fixed.issues.isEmpty)
		#expect(reworded.lastInput("formalize").contains("Reading says rains"))
		#expect(reworded.requests.first { $0.stage == "verify" }?.input.contains("If it rains, then the ground is wet.") == true)

		let entries = vocabulary.entries(in: "X→Y\nX\n∴Y")
		#expect(events.all.dropFirst(3) == [
			.started(step: .formalize, attempt: 1),
			.drafted(entries: entries, attempt: 1),
			.started(step: .verify, attempt: 1),
			.retrying(problems: ["Reading says rains, original says rained"], attempt: 1),
			.started(step: .formalize, attempt: 2),
			.drafted(entries: entries, attempt: 2),
			.started(step: .verify, attempt: 2),
		])
	}

	@Test func stillDifferentGivesNoLogic() async throws {
		let stubborn = ScriptedBackend(["gate": [gate], "breakdown": [breakdown], "formalize": [good], "verify": [differs]])
		let events = EventLog()
		let warned = try await translate(stubborn, events: events)

		#expect(warned.entries.isEmpty)
		#expect(warned.issues == [
			TranslationIssue(severity: .error, message: "Expected logic that means the same as the English, found none in 3 tries"),
			TranslationIssue(severity: .warning, message: "Reading says rains, original says rained"),
		])
		#expect(stubborn.count("verify") == 3)
		#expect(events.all.filter {
			if case .retrying = $0 {
				true
			} else {
				false
			}
		}.count == 2)
		#expect(events.all.last == .started(step: .verify, attempt: 3))
	}

	@Test func notVerifyingStopsAtTheFirstCompile() async throws {
		let trusting = ScriptedBackend(["gate": [gate], "breakdown": [breakdown], "formalize": [good]], policy: TranslationPolicy(verifies: false))
		_ = try await translate(trusting)
		#expect(trusting.count("verify") == 0)
	}

	// MARK: - Cancelling

	@Test func cancellingStopsBeforeTheNextModelCall() async throws {
		let backend = ScriptedBackend(["gate": [gate], "breakdown": [breakdown], "formalize": [good], "verify": [matches]])
		let task = Task {
			withUnsafeCurrentTask { $0?.cancel() }
			return try await translate(backend)
		}

		await #expect(throws: CancellationError.self) {
			try await task.value
		}
		#expect(backend.requests.isEmpty)
	}
}
