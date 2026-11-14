//
//  LogicChecker.swift
//  Ergo
//
//  Created by Adon Omeri on 4/11/2026.
//

import Foundation

public enum LogicVerdict: Equatable, Sendable {
	/// Every row that makes all the premises true makes the conclusion true
	case valid

	/// A row where the premises are true and the conclusion is false, keyed by letter slot.
	/// Only has the letters that matter, the argument fails however the others are set.
	/// Empty beyond a truth table, where the situation it fails in isn't just true and false letters.
	case invalid(counterexample: [Int: Bool])

	/// Couldn't be proved either way. Nothing can always settle arguments with relations like R(X,Y), and a ∀ or ∃
	/// over sets is out of reach.
	case undecided
}

public enum LogicStatus: Equatable, Sendable {
	case tautology
	case contradiction
	case contingent
	case undecided
}

public enum LogicWarning: Equatable, Sendable {
	/// Valid, but only because the conclusion is one of the premises
	case circular(premise: Int)

	/// The premises can never all be true together, so anything at all would follow
	case inconsistentPremises
}

public struct LogicFallacyMatch: Equatable, Sendable {
	/// An id from fallacies.json
	public let fallacyID: String

	/// The premises that make up the fallacious form, as indices into the argument's premises
	public let premises: [Int]

	public init(fallacyID: String, premises: [Int]) {
		self.fallacyID = fallacyID
		self.premises = premises
	}
}

public struct LogicAnalysis: Equatable, Sendable {
	public var parse: LogicParse

	/// Nil when there's no conclusion, or the input didn't parse
	public var verdict: LogicVerdict?

	public var fallacies: [LogicFallacyMatch] = []
	public var warnings: [LogicWarning] = []

	/// One per statement, only when nothing marks a conclusion
	public var statuses: [LogicStatus] = []
}

public enum LogicChecker {
	/// 4096 rows, still instant
	public static let maximumAtoms = 12

	public static func analyze(_ entries: [LogicKeyboardEntry]) -> LogicAnalysis {
		var analysis = LogicAnalysis(parse: LogicParser.parse(entries))
		guard analysis.parse.diagnostics.isEmpty else { return analysis }

		let argument = analysis.parse.expandedArgument
		let premises = argument.premises.map(\.formula)

		guard let conclusion = argument.conclusion?.formula else {
			analysis.statuses = premises.map { status(of: $0, context: premises) }
			return analysis
		}

		let formulas = premises + [conclusion]
		if formulas.allSatisfy(\.isPropositional) {
			let table = TruthTable(formulas)
			analysis.verdict = verdict(of: premises, conclusion, in: table)

			if !premises.isEmpty, table.fits,
			   !table.rows.contains(where: { row in premises.allSatisfy { table.evaluate($0, row: row) } })
			{
				analysis.warnings.append(.inconsistentPremises)
			}
		} else {
			let prover = LogicProver(context: formulas)
			analysis.verdict = switch prover.check(truths: premises, falsehoods: [conclusion]) {
				case .impossible: .valid
				case .possible: .invalid(counterexample: [:])
				case .unknown: .undecided
			}

			if !premises.isEmpty, prover.check(truths: premises) == .impossible {
				analysis.warnings.append(.inconsistentPremises)
			}
		}

		guard let verdict = analysis.verdict else { return analysis }

		switch verdict {
			case .valid:
				if let premise = premises.firstIndex(of: conclusion) {
					analysis.warnings.append(.circular(premise: premise))
				}

			case .invalid:
				analysis.fallacies = LogicFallacyForm.matches(premises: premises, conclusion: conclusion)
				if analysis.fallacies.isEmpty {
					analysis.fallacies = [LogicFallacyMatch(fallacyID: "non-sequitur", premises: Array(premises.indices))]
				}

			case .undecided:
				// Couldn't be settled, but a known bad shape is still worth calling out
				analysis.fallacies = LogicFallacyForm.matches(premises: premises, conclusion: conclusion)
		}

		return analysis
	}

	public static func status(of formula: LogicFormula) -> LogicStatus {
		status(of: formula, context: [formula])
	}

	/// `context` is what it's written with, so a letter means the same thing in all of it
	private static func status(of formula: LogicFormula, context: [LogicFormula]) -> LogicStatus {
		guard formula.isPropositional else {
			let prover = LogicProver(context: context)
			switch (prover.check(truths: [formula]), prover.check(truths: [], falsehoods: [formula])) {
				case (.impossible, _):
					return .contradiction
				case (_, .impossible):
					return .tautology
				case (.possible, .possible):
					return .contingent
				default:
					return .undecided
			}
		}

		let table = TruthTable([formula])
		guard table.fits else { return .undecided }

		let results = table.rows.map { table.evaluate(formula, row: $0) }
		if results.allSatisfy(\.self) {
			return .tautology
		}
		if !results.contains(true) {
			return .contradiction
		}
		return .contingent
	}

	private static func verdict(of premises: [LogicFormula], _ conclusion: LogicFormula, in table: TruthTable) -> LogicVerdict {
		guard table.fits else { return .undecided }

		func fails(_ row: Int) -> Bool {
			premises.allSatisfy { table.evaluate($0, row: row) } && !table.evaluate(conclusion, row: row)
		}

		guard let counterexample = table.rows.first(where: fails) else {
			return .valid
		}

		// Let go of each atom in turn, keeping it free if the argument still fails every way it could be set
		var free = 0
		for bit in 0 ..< table.atomCount {
			let candidate = free | 1 << bit
			var subset = candidate
			var stillFails = true

			while stillFails {
				stillFails = fails(counterexample & ~candidate | subset)
				if subset == 0 {
					break
				}
				subset = (subset - 1) & candidate
			}

			if stillFails {
				free = candidate
			}
		}

		return .invalid(counterexample: table.valuation(row: counterexample, ignoring: free))
	}
}

/// For what's only made of letters and ¬ ∧ ∨ ⊕ → ↔. `LogicProver` takes everything else.
struct TruthTable {
	private var atoms: [LogicFormula: Int] = [:]
	init(_ formulas: [LogicFormula]) {
		for formula in formulas {
			collect(formula)
		}
	}

	var fits: Bool {
		atoms.count <= LogicChecker.maximumAtoms
	}

	var atomCount: Int {
		atoms.count
	}

	var rows: Range<Int> {
		0 ..< (1 << min(atoms.count, LogicChecker.maximumAtoms))
	}

	func evaluate(_ formula: LogicFormula, row: Int) -> Bool {
		switch formula {
			case .truth:
				true
			case let .not(value):
				!evaluate(value, row: row)
			case let .and(left, right):
				evaluate(left, row: row) && evaluate(right, row: row)
			case let .or(left, right):
				evaluate(left, row: row) || evaluate(right, row: row)
			case let .xor(left, right):
				evaluate(left, row: row) != evaluate(right, row: row)
			case let .implies(left, right):
				!evaluate(left, row: row) || evaluate(right, row: row)
			case let .iff(left, right):
				evaluate(left, row: row) == evaluate(right, row: row)
			default:
				atoms[formula].map { row & (1 << $0) != 0 } ?? false
		}
	}

	/// Atoms whose bit is set in `ignoring` are left out
	func valuation(row: Int, ignoring: Int = 0) -> [Int: Bool] {
		var valuation: [Int: Bool] = [:]
		for (formula, bit) in atoms where ignoring & (1 << bit) == 0 {
			if case let .atom(slot) = formula {
				valuation[slot] = row & (1 << bit) != 0
			}
		}
		return valuation
	}

	private mutating func collect(_ formula: LogicFormula) {
		switch formula {
			case .truth:
				break
			case .atom:
				add(formula)
			case let .not(value):
				collect(value)
			case let .and(left, right), let .or(left, right), let .xor(left, right),
			     let .implies(left, right), let .iff(left, right):
				collect(left)
				collect(right)
			case .necessarily, .possibly, .forAll, .exists, .predicate, .relation:
				add(formula)
		}
	}

	private mutating func add(_ formula: LogicFormula) {
		if atoms[formula] == nil {
			atoms[formula] = atoms.count
		}
	}
}
