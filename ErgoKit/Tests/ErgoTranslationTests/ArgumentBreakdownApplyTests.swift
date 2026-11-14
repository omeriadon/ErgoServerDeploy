//
//  ArgumentBreakdownApplyTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 6/11/2026.
//

import ErgoLogic
import ErgoTranslation
import Foundation
import Testing

/// A breakdown becoming statements and links on a map
struct ArgumentBreakdownApplyTests {
	typealias Map = ArgumentMap<ArgumentStatement, ArgumentLinkValue>

	func breakdown(_ premises: [String], conclusion: String = "") -> ArgumentBreakdown {
		ArgumentBreakdown(kind: conclusion.isEmpty ? .statements : .argument, premises: premises, conclusion: conclusion)
	}

	func existing(_ count: Int) -> Map {
		Map(statements: (0 ..< count).map {
			ArgumentStatement(position: CanvasPoint(x: Double($0) * 300, y: 500), english: "Existing \($0)")
		})
	}

	@Test func premisesAreLinkedToTheConclusion() throws {
		let result = breakdown(["It rains.", "Rain wets the ground."], conclusion: "The ground is wet.")
			.applied(to: Map(), replacing: true)

		#expect(result.map.statements.map(\.english) == ["It rains.", "Rain wets the ground.", "The ground is wet."])
		#expect(result.added == result.map.statements.map(\.id))
		#expect(result.conclusion == result.map.statements.last?.id)
		#expect(result.map.links.count == 2)
		#expect(try Set(result.map.links.map(\.conclusion)) == [#require(result.conclusion)])
		#expect(ArgumentMapValidator.validate(result.map).isEmpty)
		#expect(result.skipped == 0)
	}

	@Test func noConclusionGivesPremisesOnly() {
		let result = breakdown(["One.", "Two."]).applied(to: Map(), replacing: true)

		#expect(result.map.statements.count == 2)
		#expect(result.map.links.isEmpty)
		#expect(result.conclusion == nil)
	}

	@Test func conclusionAloneIsOneStatement() {
		let result = breakdown([], conclusion: "Done.").applied(to: Map(), replacing: true)
		#expect(result.map.statements.map(\.english) == ["Done."])
		#expect(result.map.links.isEmpty)
	}

	@Test func emptyBreakdownLeavesTheMapAlone() {
		let map = existing(2)
		for replacing in [true, false] {
			let result = breakdown(["  ", ""]).applied(to: map, replacing: replacing)
			#expect(result.map.statements == map.statements)
			#expect(result.added.isEmpty)
		}
	}

	@Test func quotesAreTrimmedAndBlanksSkipped() {
		let result = breakdown(["  Spaced.\n", " "], conclusion: " So. ").applied(to: Map(), replacing: true)
		#expect(result.map.statements.map(\.english) == ["Spaced.", "So."])
		#expect(result.map.links.count == 1)
	}

	@Test func replacingDropsWhatWasThere() {
		let map = existing(3)
		let result = breakdown(["A."], conclusion: "B.").applied(to: map, replacing: true)

		#expect(result.map.statements.count == 2)
		#expect(!result.map.statements.contains { map.statements.map(\.id).contains($0.id) })
	}

	@Test func addingKeepsExistingStatementsWhereTheyAre() {
		let map = existing(3)
		let result = breakdown(["A.", "B."], conclusion: "C.").applied(to: map, replacing: false)

		#expect(Array(result.map.statements.prefix(3)) == map.statements)
		#expect(result.map.statements.count == 6)
		#expect(result.map.links.count == 2)
	}

	@Test func addedBlockSitsUnderTheExistingContentWithoutOverlap() {
		let map = existing(3)
		let result = breakdown(["A.", "B."], conclusion: "C.").applied(to: map, replacing: false)

		let bottom = map.statements.map { CanvasRect(center: $0.position, size: CanvasLayout.boxSize).maxY }.max() ?? 0
		let left = map.statements.map { CanvasRect(center: $0.position, size: CanvasLayout.boxSize).minX }.min() ?? 0
		let boxes = result.map.statements.map { CanvasRect(center: $0.position, size: CanvasLayout.boxSize) }

		for box in boxes.suffix(3) {
			#expect(box.minY > bottom)
			#expect(box.minX >= left)
		}
		for (index, box) in boxes.enumerated() {
			for other in boxes[(index + 1)...] {
				#expect(!box.intersects(other))
			}
		}
	}

	@Test func theCapKeepsRoomForTheConclusion() {
		let map = existing(58)
		let result = breakdown(["A.", "B.", "C."], conclusion: "D.").applied(to: map, replacing: false, maximumStatements: 60)

		#expect(result.map.statements.count == 60)
		#expect(result.map.statements.suffix(2).map(\.english) == ["A.", "D."])
		#expect(result.skippedPremises == 2)
		#expect(!result.skippedConclusion)
		#expect(result.map.links.count == 1)
		#expect(ArgumentMapValidator.validate(result.map).isEmpty)
	}

	@Test func aFullBoardTakesNothing() {
		let map = existing(60)
		let result = breakdown(["A."], conclusion: "B.").applied(to: map, replacing: false)

		#expect(result.map.statements == map.statements)
		#expect(result.added.isEmpty)
		#expect(result.skippedPremises == 1)
		#expect(result.skippedConclusion)
		#expect(result.skipped == 2)
	}

	@Test func replacingWithTooManyPremisesFillsTheBoard() {
		let premises = (0 ..< 70).map { "Premise \($0)." }
		let result = breakdown(premises, conclusion: "So.").applied(to: existing(5), replacing: true, maximumStatements: 60)

		#expect(result.map.statements.count == 60)
		#expect(result.skippedPremises == 11)
		#expect(result.map.statements.last?.english == "So.")
		#expect(result.map.links.count == 59)
	}
}
