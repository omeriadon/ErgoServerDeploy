//
//  LogicParser.swift
//  Ergo
//
//  Created by Adon Omeri on 4/11/2026.
//

import Foundation

public enum LogicParser {
	enum Side {
		case before, after
	}

	struct Segment {
		let range: Range<Int>
		let side: Side
	}

	/// The most brackets and ¬ □ ◇ ∀ ∃ inside one another. Far past anything written by hand.
	public static let maximumDepth = 24

	/// The most symbols in one statement. A chain like X∧Y∧Z… is as deep as it is long.
	public static let maximumStatementLength = 120

	/// The most symbols in a statement once every defined letter is replaced by what it stands for. Letters defined
	/// with letters multiply: five lines can stand for millions of symbols.
	public static let maximumWrittenOutLength = 5000

	public static func parse(_ entries: [LogicKeyboardEntry]) -> LogicParse {
		var parse = LogicParse()
		var segments: [Segment] = []
		var start = 0
		var depth = 0
		var side = Side.before

		func close(at index: Int) {
			if start < index {
				segments.append(Segment(range: start ..< index, side: side))
			}
			start = index + 1
		}

		for (index, entry) in entries.enumerated() {
			switch entry {
				case .delimiter("("), .delimiter("["):
					depth += 1

				case .delimiter(")"), .delimiter("]"):
					depth = max(depth - 1, 0)

				case .delimiter(","):
					if depth == 0 {
						close(at: index)
					}

				case .delimiter("\n"):
					depth = 0
					close(at: index)

				case .symbol("∴"), .symbol("⊢"), .symbol("⊨"), .symbol("∵"):
					depth = 0
					close(at: index)

					if parse.marker == nil {
						parse.marker = entry
						side = .after
					} else {
						parse.diagnostics.append(LogicDiagnostic(problem: .extraArgumentMarker(entry), range: index ..< index + 1))
					}

				case .symbol("∎"):
					close(at: index)
					parse.hasEndMarker = true

					if entries[(index + 1)...].contains(where: { $0 != .delimiter("\n") }) {
						parse.diagnostics.append(LogicDiagnostic(problem: .misplacedEndMarker, range: index ..< index + 1))
					}

				default:
					break
			}
		}
		close(at: entries.count)

		// Already reported, the conclusion count would just repeat it
		let hasExtraMarker = parse.diagnostics.contains { diagnostic in
			if case .extraArgumentMarker = diagnostic.problem {
				return true
			}
			return false
		}

		var before: [LogicStatement] = []
		var after: [LogicStatement] = []
		var failedSides: Set<Side> = []

		// Where the text really ends, ignoring trailing new lines
		let end = (entries.lastIndex { $0 != .delimiter("\n") } ?? -1) + 1

		for segment in segments {
			var parser = FormulaParser(entries: entries, range: segment.range)
			do {
				guard segment.range.count <= maximumStatementLength else {
					throw LogicDiagnostic(problem: .tooLong(limit: maximumStatementLength), range: segment.range)
				}
				if let marker = entries[segment.range].firstIndex(of: .symbol("≔")) {
					try parse.definitions.append(definition(at: marker, in: segment, marker: parse.marker, entries: entries, after: parse.definitions))
					continue
				}

				let statement = try LogicStatement(formula: parser.parseStatement(), range: segment.range)
				switch segment.side {
					case .before:
						before.append(statement)
					case .after:
						after.append(statement)
				}
			} catch var diagnostic as LogicDiagnostic {
				diagnostic.isUnfinished = isUnfinished(diagnostic, segment: segment.range, end: end)
				diagnostic.fix = fix(for: diagnostic, in: entries)
				parse.diagnostics.append(diagnostic)
				failedSides.insert(segment.side)
			} catch {}
		}

		if let circular = parse.definitions.firstCircular {
			parse.diagnostics.append(LogicDiagnostic(problem: .circularDefinition(letter: circular.name), range: circular.range))
		}

		switch parse.marker {
			case nil:
				parse.argument.premises = before

			case .symbol("∵"):
				parse.argument.conclusion = before.first
				parse.argument.premises = after
				// A conclusion that didn't parse was already reported, so don't also call it missing
				if before.count != 1, !hasExtraMarker, !failedSides.contains(.before) {
					parse.diagnostics.append(conclusionDiagnostic(count: before.count, entries: entries, end: end))
				}

			default:
				parse.argument.premises = before
				parse.argument.conclusion = after.first
				if after.count != 1, !hasExtraMarker, !failedSides.contains(.after) {
					parse.diagnostics.append(conclusionDiagnostic(count: after.count, entries: entries, end: end))
				}
		}

		// Before anything writes the letters out, which is everything from here on
		if parse.diagnostics.isEmpty, let oversized = parse.firstOversized {
			parse.diagnostics.append(oversized)
		}

		if parse.diagnostics.isEmpty {
			parse.diagnostics += sortDiagnostics(for: parse)
		}

		return parse
	}

	/// The first statement that uses a letter as both a set and a member of one
	static func sortDiagnostics(for parse: LogicParse) -> [LogicDiagnostic] {
		let argument = parse.expandedArgument
		let statements = (argument.premises + [argument.conclusion].compactMap(\.self)).sorted { $0.range.lowerBound < $1.range.lowerBound }

		var sorts = LogicSorts()
		var next = LogicDefinition.firstRenamed * 1000
		for statement in statements {
			let formula = statement.formula.uniquelyBound(next: &next, sorts: &sorts)
			sorts.add(formula)

			switch sorts.conflict {
				case nil:
					continue
				case let .letter(letter) where LogicLetters.slots.contains(letter):
					return [LogicDiagnostic(problem: .usedAsSetAndMember(letter: letter), range: statement.range)]
				case .letter, .setAsMember:
					return [LogicDiagnostic(problem: .setAsMember, range: statement.range)]
			}
		}
		return []
	}

	static func definition(
		at marker: Int,
		in segment: Segment,
		marker argumentMarker: LogicKeyboardEntry?,
		entries: [LogicKeyboardEntry],
		after earlier: [LogicDefinition]
	) throws -> LogicDefinition {
		let markerRange = marker ..< marker + 1
		let isConclusion = argumentMarker == .symbol("∵") ? segment.side == .before : segment.side == .after && argumentMarker != nil
		guard !isConclusion else {
			throw LogicDiagnostic(problem: .definitionAsConclusion, range: markerRange)
		}

		guard segment.range.lowerBound + 1 == marker, case let .variable(name) = entries[segment.range.lowerBound] else {
			throw LogicDiagnostic(problem: .definitionNeedsLetter, range: markerRange)
		}
		guard !earlier.contains(where: { $0.name == name }) else {
			throw LogicDiagnostic(problem: .redefined(letter: name), range: segment.range.lowerBound ..< marker)
		}

		var value = FormulaParser(entries: entries, range: marker + 1 ..< segment.range.upperBound)
		return try LogicDefinition(name: name, value: value.parseDefinitionValue(), range: segment.range)
	}

	static func conclusionDiagnostic(count: Int, entries: [LogicKeyboardEntry], end: Int) -> LogicDiagnostic {
		let index = entries.firstIndex { [.symbol("∴"), .symbol("⊢"), .symbol("⊨"), .symbol("∵")].contains($0) } ?? 0
		let marker = entries[index]

		guard count == 0 else {
			return LogicDiagnostic(problem: .extraConclusions(marker: marker), range: index ..< index + 1)
		}

		// Just typed ∴ and haven't got to the conclusion yet
		return LogicDiagnostic(
			problem: .missingConclusion(marker: marker),
			range: index ..< index + 1,
			isUnfinished: marker != .symbol("∵") && index + 1 == end
		)
	}

	/// Only problems at the very end of the text, where typing more would fix them
	static func isUnfinished(_ diagnostic: LogicDiagnostic, segment: Range<Int>, end: Int) -> Bool {
		switch diagnostic.problem {
			case .unclosed:
				segment.upperBound >= end
			case .expectedFormula, .expectedLetter, .setWithoutRelation, .unexpected(.symbol("∪")), .unexpected(.symbol("∩")):
				diagnostic.range.upperBound >= end
			default:
				false
		}
	}

	static func fix(for diagnostic: LogicDiagnostic, in entries: [LogicKeyboardEntry]) -> LogicFix? {
		let range = diagnostic.range

		switch diagnostic.problem {
			// ∪ and ∩ look a lot like ∨ and ∧
			case .setWithoutRelation:
				guard !entries[range].contains(.symbol("∅")) else { return nil }
				return LogicFix(range: range, replacement: entries[range].map { entry in
					switch entry {
						case .symbol("∪"): .symbol("∨")
						case .symbol("∩"): .symbol("∧")
						default: entry
					}
				})

			case .unexpected(.symbol("∪")):
				return LogicFix(range: range, replacement: [.symbol("∨")])

			case .unexpected(.symbol("∩")):
				return LogicFix(range: range, replacement: [.symbol("∧")])

			// = and ≠ between whole statements
			case .unexpected(.symbol("=")):
				return LogicFix(range: range, replacement: [.symbol("↔")])

			case .unexpected(.symbol("≠")):
				return LogicFix(range: range, replacement: [.symbol("⊕")])

			case .unexpected(.delimiter(")")), .unexpected(.delimiter("]")):
				return LogicFix(range: range, replacement: [])

			case let .mismatched(open, _):
				return LogicFix(range: range, replacement: [open == .delimiter("(") ? .delimiter(")") : .delimiter("]")])

			default:
				return nil
		}
	}
}
