//
//  LogicProverTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 7/11/2026.
//

import ErgoLogic
import Testing

/// Arguments and statements beyond a truth table, with answers from the textbook. X Y Z P Q R are the letters.
struct LogicProverTests {
	let vocabulary = LogicInputVocabulary(letters: LogicLetters.defaults)

	func analyze(_ text: String) -> LogicAnalysis {
		LogicChecker.analyze(vocabulary.entries(in: text))
	}

	func isValid(_ text: String) -> Bool {
		analyze(text).verdict == .valid
	}

	func isInvalid(_ text: String) -> Bool {
		if case .invalid = analyze(text).verdict {
			return true
		}
		return false
	}

	static let valid = [
		// S5
		"□X∴X", "X∴◇X", "□X∴□□X", "◇X∴□◇X", "□X∴◇X", "□(X→Y),□X∴□Y", "□(X∧Y)∴□X∧□Y", "□X∧□Y∴□(X∧Y)",
		"◇(X∨Y)∴◇X∨◇Y", "¬◇X∴□¬X", "¬□X∴◇¬X", "□X→□Y,□X∴□Y",
		// Identity
		"X=Y,Y=Z∴X=Z", "X=Y∴Y=X", "X=Y,P(X)∴P(Y)", "X=Y,R(X,Z)∴R(Y,Z)", "X=Y,Y≠Z∴X≠Z", "X=Y∴□(X=Y)",
		// Sets
		"X⊂Y,Y⊂Z∴X⊂Z", "X⊆Y,Y⊆Z∴X⊆Z", "X⊆Y,Y⊆X∴X=Y", "X⊂Y∴X⊆Y", "X⊂Y∴X≠Y", "P∈X,X⊆Y∴P∈Y", "P∈X∩Y∴P∈X", "P∈X∴P∈X∪Y",
		"P∉X,X=Y∴P∉Y", "X∪Y=∅∴X=∅", "X⊆Y∴X∩Y=X", "X⊆Y∴X∪Y=Y", "X=Y,Y=Z∪Q∴X=Z∪Q",
		// Quantifiers
		"∀X(P(X)→Q(X)),P(Y)∴Q(Y)", "∀XP(X)∴∃XP(X)", "∀XP(X)∴P(Y)", "P(Y)∴∃XP(X)",
		"∀X(P(X)→Q(X)),∀X(Q(X)→R(X))∴∀X(P(X)→R(X))", "∃Y∀XR(X,Y)∴∀X∃YR(X,Y)", "¬∃XP(X)∴∀X¬P(X)", "¬∀XP(X)∴∃X¬P(X)",
		"∃X(P(X)∧Q(X))∴∃XP(X)∧∃XQ(X)", "∀X(P(X)∧Q(X))∴∀XP(X)", "∀X∀YR(X,Y)∴∀Y∀XR(X,Y)", "∃X∃YR(X,Y)∴∃Y∃XR(X,Y)",
		"∀X(P(X)→Q(X)),∃X(P(X)∧R(X))∴∃X(Q(X)∧R(X))", "∀X∃Y(P(X)→Q(Y)),∀XP(X)∴∃YQ(Y)",
		"∀X(P(X)→Q(X)),∀X(Q(X)→R(X)),∀X(R(X)→Z∈Y),∃XP(X)∴Z∈Y",
		"∃XP(X),∃XQ(X),∀X∀Y(P(X)∧Q(Y)→R(X,Y))∴∃X∃YR(X,Y)",
		"∀X∃YR(X,Y),∀X∀Y(R(X,Y)→R(Y,X)),∀X∀Y∀Z(R(X,Y)∧R(Y,Z)→R(X,Z))∴∀XR(X,X)",
		"∃X∀Y(X=Y),P(Z)∴∀XP(X)",
		"∃X(P(X)∧∀Y(P(Y)→X=Y)),P(Z),P(Q)∴Z=Q",
		"∃X(X=Y∧P(X))∴P(Y)", "P(Y)∴∃X(X=Y∧P(X))",
		// Together
		"□∀XP(X)∴∀X□P(X)", "∀X□P(X)∴□∀XP(X)", "□∀XP(X)∴□P(Y)", "◇∃XP(X)∴∃X◇P(X)", "P∈X,□(P∈X→P∈Y)∴P∈Y",
	]

	static let invalid = [
		// S5
		"◇X∴X", "X∴□X", "◇X∴□X", "◇X,◇Y∴◇(X∧Y)", "□(X∨Y)∴□X∨□Y", "□(X→Y),X∴□Y", "□(X→Y)∴X→□Y",
		// Identity
		"X≠Y,Y≠Z∴X≠Z", "X=Y∴P(X)", "P(X),P(Y)∴X=Y", "R(X,Y)∴X=Y",
		// Sets
		"X⊆Y∴X⊂Y", "X⊆Y∴Y⊆X", "P∈X∪Y∴P∈X", "P∈X∴P∈X∩Y", "P∈X,X≠Y∴P∉Y", "X∩Y=∅∴X=∅", "P∈X∴X⊆Y", "X⊂Y∴Y⊂X",
		// Quantifiers
		"∃XP(X)∴∀XP(X)", "∃XP(X),∃XQ(X)∴∃X(P(X)∧Q(X))", "∀X∃YR(X,Y)∴∃Y∀XR(X,Y)", "∀X(P(X)→Q(X))∴∀X(Q(X)→P(X))",
		"∀X(P(X)→Q(X))∴∃X(P(X)∧Q(X))", "∀X(P(X)→R(X)),∀X(Q(X)→R(X))∴∀X(Q(X)→P(X))", "P(Y)∴∀XP(X)", "∃XR(X,X)∴∀X∃YR(X,Y)",
		"∀X(R(X,X))∴∀X∀Y(R(X,Y)→R(Y,X))", "∀X∀Y(R(X,Y)→R(Y,X))∴∀XR(X,X)",
		"∀X∃YR(X,Y),∀X∀Y(R(X,Y)→¬R(Y,X))∴∃XR(X,X)",
		"∃XP(X),∃XQ(X),X≠Y∴∃X(P(X)∧Q(X))",
		// Together
		"∀X◇P(X)∴◇∀XP(X)", "◇P(Y),◇Q(Y)∴◇(P(Y)∧Q(Y))",
	]

	@Test(arguments: valid)
	func provesValid(_ text: String) {
		#expect(isValid(text), "\(String(describing: analyze(text).verdict))")
	}

	@Test(arguments: invalid)
	func provesInvalid(_ text: String) {
		#expect(isInvalid(text), "\(String(describing: analyze(text).verdict))")
	}

	@Test(arguments: [
		("□X", LogicStatus.contingent),
		("□X∨¬□X", .tautology),
		("□X∧¬X", .contradiction),
		("□X→X", .tautology),
		("X→□◇X", .tautology),
		("X=X", .tautology),
		("X≠X", .contradiction),
		("X=Y", .contingent),
		("P∉∅", .tautology),
		("P∈∅", .contradiction),
		("X⊆X", .tautology),
		("X⊂X", .contradiction),
		("∅⊆X", .tautology),
		("X∪Y=Y∪X", .tautology),
		("X∩Y=Y∩X", .tautology),
		("X∪∅=X", .tautology),
		("∃X(P(X)→∀YP(Y))", .tautology),
		("∃X∀Y(X=Y)", .contingent),
		("∃X(P(X)∧¬P(X))", .contradiction),
		("∃XX=X", .tautology),
		("∀XP(X)∨∃X¬P(X)", .tautology),
	])
	func statuses(_ text: String, status: LogicStatus) {
		#expect(analyze(text).statuses == [status])
	}

	/// Sets hold things, never other sets
	@Test func aLetterIsOneSort() {
		let problems = { (text: String) in analyze(text).parse.diagnostics.map(\.problem) }

		#expect(problems("X∈Y,Y∈Z") == [.usedAsSetAndMember(letter: 2)])
		#expect(problems("X∈X") == [.usedAsSetAndMember(letter: 1)])
		#expect(problems("X∈Y,Y=Z,Z∈Q") == [.usedAsSetAndMember(letter: 3)])
		#expect(problems("P(Y),Y⊆Z") == [.usedAsSetAndMember(letter: 2)])
		#expect(problems("X∪Y∈Z") == [.setAsMember])
		#expect(problems("∅∈X") == [.setAsMember])
		#expect(problems("P(X∪Y)") == [.setAsMember])

		#expect(problems("X∈Y,X").isEmpty, "A statement is unrelated to the same letter in a comparison")
		#expect(problems("∀X(X∈Y),X⊆Y").isEmpty, "∀X's X is its own letter")
	}

	/// Nothing can settle these, so the checker has to say so and not guess
	@Test func someArgumentsCantBeSettled() {
		// Only infinitely many things can make these premises true, which no finite search can find or rule out
		let infinite = "∀X∃YR(X,Y),∀X¬R(X,X),∀X∀Y∀Z(R(X,Y)∧R(Y,Z)→R(X,Z))∴¬⊤"
		#expect(analyze(infinite).verdict == .undecided)
		#expect(analyze(infinite).feedback == .unchecked(fallacy: nil))

		// A ∀ over sets is second order
		#expect(analyze("∀X(X⊆Y)∴Y=Y").verdict == .undecided)
	}

	/// Big enough that a slow search would hold up typing
	@Test(.timeLimit(.minutes(1)))
	func hardArgumentsStayBounded() {
		let clock = ContinuousClock()
		let elapsed = clock.measure {
			_ = analyze("∀X∃Y∃Z(R(X,Y)∧R(Y,Z)∧¬R(X,Z)),∀X∃Y(R(Y,X)∧¬R(X,Y)),∀X∀Y(R(X,Y)∨R(Y,X)∨X=Y)∴¬⊤")
		}
		#expect(elapsed < .seconds(5))
	}
}
