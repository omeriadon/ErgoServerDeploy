//
//  ArgumentMapTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 6/11/2026.
//

import ErgoLogic
import Foundation
import Testing

/// Queries, ordering and validation of the plain statement and link model
struct ArgumentMapTests {
	let id = ArgumentFixtures.id

	// MARK: - Queries

	@Test func emptyMap() {
		let map = TestMap()
		#expect(map.roots.isEmpty)
		#expect(map.finalConclusions.isEmpty)
		#expect(map.topologicalOrder().isEmpty)
		#expect(ArgumentMapValidator.validate(map).isEmpty)
	}

	@Test func oneStatement() {
		let map = ArgumentFixtures.map(1)
		#expect(map.roots == [id(1)])
		#expect(!map.isConclusion(id(1)))
		#expect(!map.isFinalConclusion(id(1)))
		#expect(map.topologicalOrder() == [id(1)])
	}

	@Test func chain() {
		let map = ArgumentFixtures.map(3, links: [(1, 2), (2, 3)])
		#expect(map.premises(of: id(2)) == [id(1)])
		#expect(map.conclusions(of: id(2)) == [id(3)])
		#expect(map.isConclusion(id(2)))
		#expect(!map.isFinalConclusion(id(2)), "B feeds C, so it is not the end")
		#expect(map.isFinalConclusion(id(3)))
		#expect(map.roots == [id(1)])
		#expect(map.finalConclusions == [id(3)])
		#expect(map.topologicalOrder() == [id(1), id(2), id(3)])
		#expect(map.reaches(id(1), id(3)))
		#expect(!map.reaches(id(3), id(1)))
		#expect(!map.reaches(id(1), id(1)))
	}

	@Test func diamond() {
		var map = ArgumentFixtures.map(4, links: [(1, 2), (1, 3), (2, 4), (3, 4)])
		#expect(map.premises(of: id(4)) == [id(2), id(3)])
		#expect(map.conclusions(of: id(1)) == [id(2), id(3)])
		#expect(map.roots == [id(1)])
		#expect(map.topologicalOrder() == [id(1), id(2), id(3), id(4)])

		map.statements[1].position = CanvasPoint(x: 0, y: 500)
		#expect(map.topologicalOrder() == [id(1), id(3), id(2), id(4)], "Position breaks ties")
		#expect(map.topologicalOrder(tieBreak: .listing) == [id(1), id(2), id(3), id(4)], "Listing order ignores position")
	}

	@Test func orderPutsPremisesFirstWhateverTheListing() {
		var map = ArgumentFixtures.map(3, links: [(3, 2), (2, 1)])
		#expect(map.topologicalOrder(tieBreak: .listing) == [id(3), id(2), id(1)])
		map.statements.reverse()
		#expect(map.topologicalOrder(tieBreak: .listing) == [id(3), id(2), id(1)])
	}

	@Test func unlinkedStatementsAreRootsAndOrderedByPosition() {
		var map = ArgumentFixtures.map(3)
		map.statements[0].position = CanvasPoint(x: 0, y: 200)
		map.statements[1].position = CanvasPoint(x: 0, y: 100)
		map.statements[2].position = CanvasPoint(x: -50, y: 100)
		#expect(map.roots == [id(1), id(2), id(3)])
		#expect(map.topologicalOrder() == [id(3), id(2), id(1)], "Top to bottom, then left to right")
	}

	@Test func duplicateLinksCountOnce() {
		var map = ArgumentFixtures.map(2, links: [(1, 2)])
		map.links.append(ArgumentLinkValue(id: id(9), premise: id(1), conclusion: id(2)))
		#expect(map.premises(of: id(2)) == [id(1)])
		#expect(map.topologicalOrder() == [id(1), id(2)])
	}

	@Test func brokenMapsStillGetAnOrder() {
		let cyclic = ArgumentFixtures.map(4, links: [(1, 2), (2, 3), (3, 2), (3, 4)])
		#expect(cyclic.topologicalOrder() == [id(1), id(2), id(3), id(4)], "Cycle members come last, nothing is dropped")

		var dangling = ArgumentFixtures.map(2, links: [(1, 2)])
		dangling.links.append(ArgumentLinkValue(premise: id(1), conclusion: id(99)))
		#expect(dangling.topologicalOrder() == [id(1), id(2)])

		var repeated = ArgumentFixtures.map(2)
		repeated.statements.append(repeated.statements[0])
		#expect(repeated.topologicalOrder().count == 2)
	}

	@Test func selfLinksAreIgnoredByQueries() {
		let map = ArgumentFixtures.map(1, links: [(1, 1)])
		#expect(!map.isConclusion(id(1)))
		#expect(map.premises(of: id(1)).isEmpty)
		#expect(map.roots == [id(1)])
	}

	// MARK: - Validator

	@Test func validMapsHaveNoProblems() {
		#expect(ArgumentMapValidator.validate(ArgumentFixtures.map(4, links: [(1, 2), (1, 3), (2, 4), (3, 4)])).isEmpty)
	}

	@Test func selfLink() {
		let map = ArgumentFixtures.map(2, links: [(1, 1)])
		#expect(ArgumentMapValidator.validate(map) == [.selfLink(link: id(1101), statement: id(1))])
	}

	@Test func danglingLinks() {
		var map = ArgumentFixtures.map(1)
		map.links = [ArgumentFixtures.link(1, 2), ArgumentFixtures.link(3, 1)]
		#expect(ArgumentMapValidator.validate(map) == [
			.danglingLink(link: id(1102), missing: id(2)),
			.danglingLink(link: id(1301), missing: id(3)),
		])
	}

	@Test func duplicateLink() {
		var map = ArgumentFixtures.map(2, links: [(1, 2)])
		map.links.append(ArgumentLinkValue(id: id(7), premise: id(1), conclusion: id(2)))
		#expect(ArgumentMapValidator.validate(map) == [.duplicateLink(link: id(7), original: id(1102))])
	}

	@Test func duplicateIDs() {
		var map = ArgumentFixtures.map(2, links: [(1, 2)])
		map.statements.append(map.statements[0])
		map.links.append(map.links[0])
		let problems = ArgumentMapValidator.validate(map)
		#expect(problems.contains(.duplicateStatement(id(1))))
		#expect(problems.contains(.duplicateLinkID(id(1102))))
	}

	@Test func cyclesAreRejected() {
		let two = ArgumentMapValidator.validate(ArgumentFixtures.map(2, links: [(1, 2), (2, 1)]))
		#expect(two == [.cycle([id(1), id(2)])])

		let three = ArgumentMapValidator.validate(ArgumentFixtures.map(4, links: [(4, 1), (1, 2), (2, 3), (3, 1)]))
		#expect(three == [.cycle([id(1), id(2), id(3)])], "Only the loop is reported, not the tail leading into it")
	}

	@Test func diamondIsNotACycle() {
		#expect(ArgumentMapValidator.validate(ArgumentFixtures.map(5, links: [(1, 2), (1, 3), (2, 4), (3, 4), (4, 5), (1, 5)])).isEmpty)
	}

	@Test func aLongChainDoesNotOverflowTheStack() {
		let count = 20000
		let map = TestMap(
			statements: (1 ... count).map { ArgumentFixtures.statement($0) },
			links: (1 ..< count).map { ArgumentFixtures.link($0, $0 + 1) }
		)
		#expect(ArgumentMapValidator.validate(map, maximumStatements: count).isEmpty)
		#expect(map.topologicalOrder().first == id(1))
	}

	@Test func statementLimit() {
		let map = ArgumentFixtures.map(61)
		#expect(ArgumentMapValidator.validate(map) == [.tooManyStatements(limit: 60, found: 61)])
		#expect(ArgumentMapValidator.validate(ArgumentFixtures.map(60)).isEmpty)
		#expect(ArgumentMapValidator.validate(map, maximumStatements: 100).isEmpty)
		#expect(ArgumentMapValidator.validate(ArgumentFixtures.map(3), maximumStatements: 2) == [.tooManyStatements(limit: 2, found: 3)])
	}

	@Test func badLinksAreNotAlsoCycles() {
		var map = ArgumentFixtures.map(2, links: [(1, 2)])
		map.links.append(ArgumentLinkValue(id: id(8), premise: id(2), conclusion: id(2)))
		#expect(ArgumentMapValidator.validate(map) == [.selfLink(link: id(8), statement: id(2))])
	}

	@Test func addingALinkIsCheckedBeforeItIsDrawn() {
		let map = ArgumentFixtures.map(3, links: [(1, 2), (2, 3)])
		func problem(_ premise: Int, _ conclusion: Int) -> ArgumentMapProblem? {
			ArgumentMapValidator.problem(adding: ArgumentLinkValue(id: id(9), premise: id(premise), conclusion: id(conclusion)), to: map)
		}

		#expect(problem(1, 3) == nil)
		#expect(problem(2, 2) == .selfLink(link: id(9), statement: id(2)))
		#expect(problem(1, 2) == .duplicateLink(link: id(9), original: id(1102)))
		#expect(problem(3, 1) == .cycle([id(3), id(1)]))
		#expect(problem(1, 8) == .danglingLink(link: id(9), missing: id(8)))
	}

	@Test func messagesReadLikeDiagnostics() {
		#expect(ArgumentMapProblem.tooManyStatements(limit: 60, found: 61).message == "Expected at most 60 statements, found 61")
		#expect(ArgumentMapProblem.cycle([id(1), id(2)]).message == "Expected arrows that never loop back, found a cycle through 2 statements")
		#expect(ArgumentMapProblem.selfLink(link: id(1), statement: id(1)).message.hasPrefix("Expected"))
		#expect(ArgumentMapProblem.selfLink(link: id(1), statement: id(1)).message.contains("found"))
	}
}
