//
//  ArgumentFixtures.swift
//  ErgoKit
//
//  Created by Adon Omeri on 6/11/2026.
//

import ErgoLogic
import Foundation

typealias TestMap = ArgumentMap<ArgumentStatement, ArgumentLinkValue>

/// Small maps with ids you can read: statement 1 is `id(1)`, and so on
enum ArgumentFixtures {
	static func id(_ number: Int) -> UUID {
		UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", number))")!
	}

	/// `x` and `y` default to a row, so reading order is the numbering
	static func statement(_ number: Int, english: String = "", x: Double? = nil, y: Double = 0) -> ArgumentStatement {
		ArgumentStatement(id: id(number), position: CanvasPoint(x: x ?? Double(number) * 400, y: y), english: english)
	}

	static func link(_ premise: Int, _ conclusion: Int, number: Int? = nil) -> ArgumentLinkValue {
		ArgumentLinkValue(id: id(1000 + (number ?? premise * 100 + conclusion)), premise: id(premise), conclusion: id(conclusion))
	}

	/// Statements 1...count, linked as given
	static func map(_ count: Int, links: [(Int, Int)] = []) -> TestMap {
		TestMap(statements: (1 ... max(count, 1)).prefix(count).map { statement($0) }, links: links.map { link($0.0, $0.1) })
	}

	/// Hands out ids 5001, 5002… so new statements and links can be recognised
	final class Generator {
		var next = 5000

		func callAsFunction() -> UUID {
			next += 1
			return ArgumentFixtures.id(next)
		}
	}
}
