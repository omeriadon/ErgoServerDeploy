//
//  TranslationCodingTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoLogic
import ErgoTranslation
import Foundation
import Testing

/// Boards saved before ErgoKit existed have to keep decoding, so these are the synthesized formats as they were then
struct TranslationCodingTests {
	@Test func savedTranslationStillDecodes() throws {
		let saved = #"{"english":"If it rains, it pours.","entries":[{"variable":{"_0":1}},{"symbol":{"_0":"→"}},{"variable":{"_0":2}}],"descriptors":["it rains","it pours","","","",""],"issues":[{"message":"Expected statement","severity":"error"}]}"#
		let translation = Translation(
			english: "If it rains, it pours.",
			entries: [.variable(1), .symbol("→"), .variable(2)],
			descriptors: ["it rains", "it pours", "", "", "", ""],
			issues: [TranslationIssue(severity: .error, message: "Expected statement")]
		)

		#expect(try JSONDecoder().decode(Translation.self, from: Data(saved.utf8)) == translation)
		#expect(try roundTrip(translation) == translation)
	}

	@Test func savedEmptyTranslationStillDecodes() throws {
		let saved = #"{"english":"X","entries":[],"descriptors":["","","","","",""],"issues":[]}"#
		#expect(try JSONDecoder().decode(Translation.self, from: Data(saved.utf8)) == Translation(english: "X"))
	}

	@Test func savedIssueStillDecodes() throws {
		let saved = #"{"message":"Reading says rains","severity":"warning"}"#
		#expect(try JSONDecoder().decode(TranslationIssue.self, from: Data(saved.utf8)) == TranslationIssue(severity: .warning, message: "Reading says rains"))
	}

	@Test func eventsRoundTrip() throws {
		let events: [TranslationEvent] = [
			.started(step: .formalize, attempt: 2),
			.foundClaims(premises: ["It rained"], conclusion: "", descriptors: LogicLetters.emptyDescriptors),
			.drafted(entries: [.variable(1), .symbol("∧"), .variable(2)], attempt: 1),
			.retrying(problems: ["Expected statement after '→'"], attempt: 1),
		]
		#expect(try roundTrip(events) == events)
	}

	@Test func breakdownRoundTrips() throws {
		let breakdown = ArgumentBreakdown(
			kind: .statements,
			premises: ["It rained"],
			claims: [BreakdownStage.Output.Claim(meaning: "It rains", descriptor: "it rains")],
			descriptors: ["it rains", "", "", "", "", ""],
			issues: [TranslationIssue(severity: .warning, message: "W")]
		)
		#expect(try roundTrip(breakdown) == breakdown)
		#expect(ArgumentBreakdown(kind: .neither).descriptors == LogicLetters.emptyDescriptors)
	}

	private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
		try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
	}
}
