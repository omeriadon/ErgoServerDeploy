//
//  LogicParserTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoLogic
import Testing

/// Precedence, printing, validity, every named fallacy form, counterexamples, warnings, statuses, and diagnostics
struct LogicParserTests {
	let letters = LogicLetters.defaults
	let vocabulary = LogicInputVocabulary(letters: LogicLetters.defaults)

	func analyze(_ text: String) -> LogicAnalysis {
		let entries = vocabulary.entries(in: text)
		#expect(vocabulary.text(for: entries) == text, "Not keyboard text: \(text)")
		return LogicChecker.analyze(entries)
	}

	func fallacies(_ text: String) -> [String] {
		analyze(text).fallacies.map(\.fallacyID)
	}

	func problems(_ text: String) -> [LogicProblem] {
		analyze(text).parse.diagnostics.map(\.problem)
	}

	func roundTrip(_ text: String) -> String? {
		let parse = analyze(text).parse
		guard parse.diagnostics.isEmpty, parse.argument.conclusion == nil, parse.argument.premises.count == 1 else { return nil }
		return parse.argument.premises[0].formula.text(letters: letters)
	}

	/// Precedence and printing
	@Test func precedenceAndPrinting() {
		#expect(roundTrip("X∧Y∨Z") == "X ∧ Y ∨ Z")
		#expect(roundTrip("X∧(Y∨Z)") == "X ∧ (Y ∨ Z)")
		#expect(roundTrip("X→Y→Z") == "X → Y → Z")
		#expect(roundTrip("(X→Y)→Z") == "(X → Y) → Z")
		#expect(roundTrip("¬(X∧Y)") == "¬(X ∧ Y)")
		#expect(roundTrip("[X↔Y]") == "X ↔ Y")
		#expect(roundTrip("∀X∃YP(X,Y)") == "∀X ∃Y P(X, Y)")
		#expect(roundTrip("X∪Y⊂Z") == "X ∪ Y ⊂ Z")
		#expect(roundTrip("¬X=Y") == "¬X = Y")
		#expect(roundTrip("□(X→Y)") == "□(X → Y)")
	}

	/// Valid forms
	@Test func validForms() {
		#expect(analyze("X→Y,X∴Y").verdict == .valid)
		#expect(analyze("X→Y\n¬Y\n∴¬X").verdict == .valid)
		#expect(analyze("X∨Y,¬X⊢Y").verdict == .valid)
		#expect(analyze("Y∵X→Y,X").verdict == .valid)
		#expect(analyze("X→Y,Y→Z∴X→Z").verdict == .valid)
		#expect(analyze("X→Y∴¬Y→¬X").verdict == .valid)
		#expect(analyze("∴X∨¬X").verdict == .valid)
		#expect(analyze("X→Y,X∴Y\n∎").verdict == .valid)
		#expect(analyze("X⊕Y,X∴¬Y").verdict == .valid, "Exclusive or really does rule the other out")
	}

	/// Every propositional fallacy, by name
	@Test func everyPropositionalFallacy() {
		#expect(fallacies("X→Y,Y∴X") == ["affirming-the-consequent"])
		#expect(fallacies("X→Y,¬X∴¬Y") == ["denying-the-antecedent"])
		#expect(fallacies("X∨Y,X∴¬Y") == ["affirming-a-disjunct"])
		#expect(fallacies("X∨Y,Y∴¬X") == ["affirming-a-disjunct"])
		#expect(fallacies("¬(X∧Y),¬X∴Y") == ["denying-a-conjunct"])
		#expect(fallacies("X→Y∴Y→X") == ["commutation-of-conditionals"])
		#expect(fallacies("X→Y∴¬X→¬Y") == ["negating-antecedent-and-consequent"])
		#expect(fallacies("X∴Y") == ["non-sequitur"])
	}

	/// Extra premises don't hide the form, and the match says which premises were involved
	@Test func extraPremisesDontHideTheForm() {
		let extra = analyze("Z,X→Y,Y∴X")
		#expect(extra.fallacies == [LogicFallacyMatch(fallacyID: "affirming-the-consequent", premises: [1, 2])])
	}

	/// Compound pieces still match the form
	@Test func compoundPiecesStillMatch() {
		#expect(fallacies("(X∧Y)→¬Z,¬Z∴X∧Y") == ["affirming-the-consequent"])
	}

	/// Counterexample is a real one, with only the letters that matter
	@Test func counterexamplesKeepOnlyLettersThatMatter() {
		#expect(analyze("X→Y,Y∴X").verdict == .invalid(counterexample: [1: false, 2: true]))
		#expect(analyze("¬X→Z∴X→R").verdict == .invalid(counterexample: [1: true, 6: false]), "Z can be anything, so it's left out")
	}

	/// A → A, A ∴ A is fine, not affirming the consequent
	@Test func repeatedFormulaIsntAFallacy() {
		#expect(analyze("X→X,X∴X").fallacies.isEmpty)
	}

	/// Modal and first order shapes, named as well as proved invalid
	@Test func modalAndFirstOrderShapes() {
		#expect(analyze("□(X→Y),X∴□Y").verdict == .invalid(counterexample: [:]))
		#expect(fallacies("□(X→Y),X∴□Y") == ["modal-scope-fallacy"])
		#expect(fallacies("□(X→Y)∴X→□Y") == ["modal-scope-fallacy"])
		#expect(fallacies("∀X∃YR(X,Y)∴∃Y∀XR(X,Y)") == ["quantifier-shift-fallacy"])
		#expect(fallacies("∀X(P(X)→Q(X))∴∃X(P(X)∧Q(X))") == ["existential-fallacy"])
		#expect(fallacies("∀X(P(X)→Q(X))∴∀X(Q(X)→P(X))") == ["illicit-conversion"])
		#expect(fallacies("∀X(P(X)→R(X)),∀X(Q(X)→R(X))∴∀X(Q(X)→P(X))") == ["undistributed-middle"])
		#expect(analyze("□X→□Y,□X∴□Y").verdict == .valid, "Valid by propositional form alone")
		#expect(analyze("X=Y,Y=Z∴X=Z").verdict == .valid)
		#expect(analyze("X=Y,Y=Z∴X=Z").fallacies.isEmpty)
	}

	/// Warnings
	@Test func warnings() {
		#expect(analyze("X,Y∴X").warnings == [.circular(premise: 0)])
		#expect(analyze("X,¬X∴Y").warnings == [.inconsistentPremises])
	}

	/// No conclusion: each line on its own
	@Test func statusesWithoutAConclusion() {
		#expect(analyze("X∨¬X\nX∧¬X\nX→Y").statuses == [.tautology, .contradiction, .contingent])
		#expect(analyze("□X").statuses == [.contingent])
		#expect(analyze("□X∨¬□X").statuses == [.tautology])
	}

	/// Syntax problems point at the right entry
	@Test func syntaxProblems() {
		#expect(problems("X∧") == [.expectedFormula(after: .symbol("∧"))])
		#expect(problems("X∧∧Y") == [.expectedFormula(after: .symbol("∧"))])
		#expect(problems("XY") == [.missingConnective(before: .variable(2))])
		#expect(problems("(X∧Y") == [.unclosed(.delimiter("("))])
		#expect(problems("(X∧Y]") == [.mismatched(open: .delimiter("("), close: .delimiter("]"))])
		#expect(problems("X)") == [.unexpected(.delimiter(")"))])
		#expect(problems("∀(X)") == [.expectedLetter(after: .symbol("∀"))])
		#expect(problems("(X∪Y)") == [.setWithoutRelation(.symbol("∪"))])
		#expect(problems("X∴Y∴Z") == [.extraArgumentMarker(.symbol("∴"))])
		#expect(problems("X∴Y,Z") == [.extraConclusions(marker: .symbol("∴"))])
		#expect(problems("X∴") == [.missingConclusion(marker: .symbol("∴"))])
		#expect(problems("X∴Y→") == [.expectedFormula(after: .symbol("→"))], "A broken conclusion isn't also a missing one")
		#expect(problems("P,∴(X∪P)") == [.setWithoutRelation(.symbol("∪"))])
		#expect(problems("(X,Y)") == [.unexpected(.delimiter(","))])
		#expect(problems("X∧Y≔Z") == [.definitionNeedsLetter])
		#expect(problems("X∴Y≔Z") == [.definitionAsConclusion])
		#expect(problems("X≔Y∵Z") == [.definitionAsConclusion])
		#expect(problems("X≔Y,X≔Z") == [.redefined(letter: 1)])
		#expect(problems("X≔X∧Y") == [.circularDefinition(letter: 1)])
		#expect(problems("X≔Y,Y≔X") == [.circularDefinition(letter: 1)])
		#expect(problems("X∎Y") == [.misplacedEndMarker])
		#expect(problems("→X") == [.unexpected(.symbol("→"))])
		#expect(analyze("X∧").parse.diagnostics.first?.range == 1 ..< 2)
		#expect(analyze("X\n(Y\nZ∧").parse.diagnostics.map(\.range) == [2 ..< 3, 6 ..< 7], "Each line reports on its own")
		#expect(analyze("X∧").verdict == nil)
	}

	/// Stopping partway isn't an error yet, but a mistake further back still is
	@Test func unfinishedIsntAnError() {
		#expect(analyze("X∧").feedback == .unfinished(LogicDiagnostic(problem: .expectedFormula(after: .symbol("∧")), range: 1 ..< 2, isUnfinished: true)))
		#expect(analyze("X→Y\n∴").feedback.map {
			if case .unfinished = $0 {
				true
			} else {
				false
			}
		} == true)
		#expect(analyze("(X∧Y\n").feedback.map {
			if case .unfinished = $0 {
				true
			} else {
				false
			}
		} == true)
		#expect(analyze("X∧,Y").feedback.map {
			if case .error = $0 {
				true
			} else {
				false
			}
		} == true)
		#expect(analyze("X∧∧Y").feedback.map {
			if case .error = $0 {
				true
			} else {
				false
			}
		} == true)
		#expect(analyze("X)\nY∧").feedback.map {
			if case .error = $0 {
				true
			} else {
				false
			}
		} == true)
		#expect(analyze("X∧").highlights.isEmpty, "Nothing to mark while still typing")
	}

	/// Likely fixes
	@Test func likelyFixes() {
		#expect(analyze("P,∴(X∪P)").parse.diagnostics.first?.fix == LogicFix(range: 4 ..< 7, replacement: [.variable(1), .symbol("∨"), .variable(4)]))
		#expect(analyze("(X∧Y)=Z").parse.diagnostics.first?.fix == LogicFix(range: 5 ..< 6, replacement: [.symbol("↔")]))
		#expect(analyze("(X∧Y]").parse.diagnostics.first?.fix == LogicFix(range: 4 ..< 5, replacement: [.delimiter(")")]))
		#expect(analyze("X)").parse.diagnostics.first?.fix == LogicFix(range: 1 ..< 2, replacement: []))
		#expect(analyze("X∅").parse.diagnostics.first?.fix == nil)
	}

	/// A defined letter is checked as what it stands for
	@Test func definitions() {
		#expect(analyze("X≔Y∧Z,X∴Y").verdict == .valid)
		#expect(analyze("X≔Y,X∴Z").verdict == .invalid(counterexample: [2: true, 3: false]))
		#expect(analyze("X≔Y,Y≔Z,X∴Z").verdict == .valid, "Through another definition")
		#expect(analyze("X,X≔Y∴Y").verdict == .valid, "Wherever it's written")
		#expect(analyze("X≔Y∨¬Y\nX").statuses == [.tautology])
		#expect(analyze("Z≔X∪Y,P∈Z∴P∈X∪Y").verdict == .valid, "A set")
		#expect(analyze("Z≔X,P∈Z∴P∈X").verdict == .valid, "A name for a set")
		#expect(analyze("X≔Y,∀XP(X)∴∀XP(X)").verdict == .valid, "A bound letter isn't the defined one")
		#expect(analyze("X≔Y,∀Y(P(X)→Q(Y))∴∀Y(P(Y)→Q(Y))").verdict == .invalid(counterexample: [:]), "Not captured by ∀Y")
		#expect(analyze("X≔Y,∀Y(P(X)→Q(Y)),P(Y)∴∀YQ(Y)").verdict == .valid, "The Y outside ∀Y")
		#expect(analyze("X≔Y,∀Y(X→P(Y))∴∀Y(Y→P(Y))").verdict == .valid, "A statement letter isn't bound")
		#expect(analyze("X≔Y").feedback == nil, "Claims nothing, so there's nothing to say")
		#expect(analyze("X≔").feedback.map {
			if case .unfinished = $0 {
				true
			} else {
				false
			}
		} == true)
	}

	/// One result
	@Test func oneResult() {
		#expect(analyze("X→Y,X∴Y").feedback == .valid)
		#expect(analyze("X,Y∴X").feedback == .circular(premise: 0))
		#expect(analyze("X,¬X∴Y").feedback == .contradictoryPremises)
		#expect(analyze("X∴Y").feedback == .invalid(counterexample: [1: true, 2: false], fallacy: nil), "No named form, so no non sequitur on top")
		#expect(analyze("X→Y,Y∴X").feedback == .invalid(counterexample: [1: false, 2: true], fallacy: LogicFallacyMatch(fallacyID: "affirming-the-consequent", premises: [0, 1])))
		#expect(analyze("∀X(X⊆Y)∴Y=Y").feedback == .unchecked(fallacy: nil))
		#expect(analyze("X∨¬X").feedback == .statuses([.tautology]))
	}

	/// Highlights point at what's wrong
	@Test func highlights() {
		#expect(analyze("X∧∧Y").highlights == [LogicHighlight(range: 1 ..< 2, kind: .error)])
		#expect(analyze("X∧∧Y\n(Z").highlights.count == 1, "Only the first error")
		#expect(analyze("Z,X→Y,Y∴X").highlights.map(\.range) == [2 ..< 5, 6 ..< 7, 8 ..< 9], "The form's premises and the conclusion, not the extra premise")
		#expect(analyze("X∴Y").highlights == [LogicHighlight(range: 2 ..< 3, kind: .fallacy)], "A non sequitur only marks the conclusion")
		#expect(analyze("X→Y,X∴Y").highlights.isEmpty)
		#expect(analyze("X,Y∴X").highlights.map(\.range) == [0 ..< 1, 4 ..< 5])
	}

	/// Messages read in the current letters
	@Test func messagesUseCurrentLetters() {
		let other = ["A", "B", "C", "D", "E", "F"]
		#expect(LogicProblem.missingConnective(before: .variable(2)).message(letters: other) == "Expected connective before 'B'")
		#expect(LogicProblem.expectedFormula(after: .symbol("∧")).message(letters: other) == "Expected statement after '∧'")
		#expect(LogicProblem.setWithoutRelation(.symbol("∪")).message(letters: other) == "'∪' is set union, not 'or'")
		#expect(LogicProblem.mismatched(open: .delimiter("("), close: .delimiter("]")).message(letters: other) == "Expected ')' to close '(', found ']'")
	}
}
