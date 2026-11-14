//
//  LogicHighlight.swift
//  Ergo
//
//  Created by Adon Omeri on 5/11/2026.
//

import Foundation

/// A stretch of the editor to mark, in entry indices
public struct LogicHighlight: Equatable, Sendable {
	public enum Kind: Equatable, Sendable {
		/// Doesn't parse
		case error

		/// Parses, but the reasoning is off
		case fallacy
	}

	public let range: Range<Int>
	public let kind: Kind

	public init(range: Range<Int>, kind: Kind) {
		self.range = range
		self.kind = kind
	}
}

public extension LogicAnalysis {
	/// Marks exactly what `feedback` talks about, so the text and the message line up
	var highlights: [LogicHighlight] {
		let premises = parse.argument.premises
		let conclusion = parse.argument.conclusion.map { [$0.range] } ?? []

		func involved(_ fallacy: LogicFallacyMatch?) -> [Range<Int>] {
			guard let fallacy else { return [] }
			return fallacy.premises.map { premises[$0].range } + conclusion
		}

		if case let .error(diagnostic) = feedback {
			return [LogicHighlight(range: diagnostic.range, kind: .error)]
		}

		let ranges: [Range<Int>] = switch feedback {
			case .error, .unfinished, .valid, .statuses, nil:
				[]
			case .contradictoryPremises:
				premises.map(\.range)
			case let .circular(premise):
				[premises[premise].range] + conclusion
			// Nothing in particular is to blame for a non sequitur, the conclusion just doesn't follow
			case let .invalid(_, fallacy):
				fallacy == nil ? conclusion : involved(fallacy)
			case let .unchecked(fallacy):
				involved(fallacy)
		}

		return ranges.map { LogicHighlight(range: $0, kind: .fallacy) }
	}
}
