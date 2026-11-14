//
//  BoardTemplateTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 14/11/2026.
//

import ErgoLogic
import Foundation
import Testing

/// Every template makes a board the validator accepts, with its cards clear of each other
struct BoardTemplateTests {
	static let shaped = BoardTemplate.allCases.filter { $0 != .blank }

	func applied(_ template: BoardTemplate) -> (map: TestMap, placeholders: [UUID: String]) {
		var map = TestMap()
		let generator = ArgumentFixtures.Generator()
		let placeholders = template.apply(to: &map, makeID: generator.callAsFunction)
		return (map, placeholders)
	}

	@Test(arguments: shaped)
	func isValid(_ template: BoardTemplate) {
		let (map, _) = applied(template)
		#expect(map.statements.count == template.cards.count)
		#expect(map.links.count == template.links.count)
		#expect(ArgumentMapValidator.validate(map).isEmpty)
	}

	@Test(arguments: shaped)
	func cardsDontOverlap(_ template: BoardTemplate) {
		let (map, _) = applied(template)
		let boxes = map.statements.map { CanvasRect(center: $0.position, size: CanvasLayout.boxSize) }
		for (index, box) in boxes.enumerated() {
			for other in boxes[(index + 1)...] {
				#expect(!box.intersects(other, margin: CanvasLayout.minimumGap))
			}
		}
	}

	@Test(arguments: shaped)
	func everyCardSaysWhatGoesInIt(_ template: BoardTemplate) {
		let (map, placeholders) = applied(template)
		for statement in map.statements {
			#expect(statement.english.isEmpty)
			#expect(placeholders[statement.id]?.isEmpty == false)
		}
	}

	@Test
	func blankLeavesTheMap() {
		var map = ArgumentFixtures.map(1)
		let placeholders = BoardTemplate.blank.apply(to: &map)
		#expect(placeholders.isEmpty)
		#expect(map.statements.map(\.id) == [ArgumentFixtures.id(1)])
	}
}
