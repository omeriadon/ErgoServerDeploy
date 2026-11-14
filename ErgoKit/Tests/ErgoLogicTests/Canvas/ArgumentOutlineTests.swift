//
//  ArgumentOutlineTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 14/11/2026.
//

import ErgoLogic
import Foundation
import Testing

/// The board as an indented list, and that list as markdown
struct ArgumentOutlineTests {
	let id = ArgumentFixtures.id

	typealias Row = ArgumentOutline.Row

	@Test func emptyMap() {
		let outline = ArgumentOutline(TestMap())
		#expect(outline.arguments.isEmpty)
		#expect(outline.unlinked.isEmpty)
	}

	@Test func unlinkedStatementsComeAfter() {
		let outline = ArgumentOutline(ArgumentFixtures.map(3, links: [(1, 2)]))
		#expect(outline.arguments == [[Row(statement: id(2), depth: 0), Row(statement: id(1), depth: 1)]])
		#expect(outline.unlinked == [id(3)])
	}

	@Test func chainNests() {
		let outline = ArgumentOutline(ArgumentFixtures.map(3, links: [(1, 2), (2, 3)]))
		#expect(outline.arguments == [[
			Row(statement: id(3), depth: 0),
			Row(statement: id(2), depth: 1),
			Row(statement: id(1), depth: 2),
		]])
	}

	@Test func premisesInReadingOrder() {
		var map = ArgumentFixtures.map(3, links: [(2, 3), (1, 3)])
		map.statements[2].position = CanvasPoint(x: 400, y: 500)
		let outline = ArgumentOutline(map)
		#expect(outline.arguments.first?.map(\.statement) == [id(3), id(1), id(2)], "Left to right, whatever the link order")
	}

	@Test func sharedPremiseIsListedUnderEachButExpandedOnce() {
		// 1 → 2 → 4, 2 → 5, so 2 supports both 4 and 5
		let outline = ArgumentOutline(ArgumentFixtures.map(5, links: [(1, 2), (2, 4), (2, 5)]))
		#expect(outline.arguments == [
			[Row(statement: id(4), depth: 0), Row(statement: id(2), depth: 1), Row(statement: id(1), depth: 2)],
			[Row(statement: id(5), depth: 0), Row(statement: id(2), depth: 1, isRepeat: true)],
		])
		#expect(outline.unlinked == [id(3)])
	}

	@Test func diamondDoesNotRepeatBelowTheRepeat() {
		let map = ArgumentFixtures.map(4, links: [(1, 2), (1, 3), (2, 4), (3, 4)])
		let outline = ArgumentOutline(map)
		#expect(outline.arguments == [[
			Row(statement: id(4), depth: 0),
			Row(statement: id(2), depth: 1),
			Row(statement: id(1), depth: 2),
			Row(statement: id(3), depth: 1),
			Row(statement: id(1), depth: 2, isRepeat: true),
		]])
	}

	@Test func cycleStillListsEveryStatement() {
		let outline = ArgumentOutline(ArgumentFixtures.map(3, links: [(1, 2), (2, 1)]))
		let listed = Set(outline.arguments.flatMap { $0.map(\.statement) })
		#expect(listed == [id(1), id(2)])
		#expect(outline.unlinked == [id(3)])
		#expect(outline.arguments.flatMap(\.self).count <= 3, "No more rows than statements and links")
	}

	@Test func danglingAndSelfLinksAreIgnored() {
		var map = ArgumentFixtures.map(2, links: [(1, 1)])
		map.links.append(ArgumentFixtures.link(2, 9))
		let outline = ArgumentOutline(map)
		#expect(outline.arguments.isEmpty)
		#expect(outline.unlinked == [id(1), id(2)])
	}

	@Test func rowsStayBoundedOnADenseMap() {
		// Every statement a premise of every later one: 12 statements, 66 links
		let count = 12
		var pairs: [(Int, Int)] = []
		for premise in 1 ... count {
			for conclusion in premise + 1 ..< count + 1 {
				pairs.append((premise, conclusion))
			}
		}
		let outline = ArgumentOutline(ArgumentFixtures.map(count, links: pairs))
		#expect(outline.arguments.count == 1)
		#expect(outline.arguments.flatMap(\.self).count <= count + pairs.count)
	}

	// MARK: - Markdown

	@Test func markdown() {
		var map = ArgumentFixtures.map(4, links: [(1, 2)])
		map.statements[0].english = "All men are mortal"
		map.statements[1].english = "Socrates is\nmortal"
		map.statements[2].english = "# Not a heading"
		let sources = [
			ArgumentOutlineSource(title: "Notes", text: "First line\n\nSecond", members: [id(1), id(99)]),
			ArgumentOutlineSource(title: "Site", link: URL(string: "https://example.com")),
		]

		let text = ArgumentOutlineMarkdown.text(title: "Mortality", map: map, sources: sources)
		#expect(text == """
		# Mortality

		## Arguments

		- ∴ Socrates is mortal
		  - All men are mortal

		## Other statements

		- \\# Not a heading
		- *Empty statement*

		## Sources

		### Notes

		> First line
		>
		> Second

		- All men are mortal

		### Site

		<https://example.com>

		""")
	}

	@Test func markdownMarksRepeats() {
		let map = ArgumentFixtures.map(4, links: [(1, 2), (1, 3), (2, 4), (3, 4)])
		let text = ArgumentOutlineMarkdown.text(title: "", map: map)
		#expect(text.hasPrefix("# Untitled\n"))
		#expect(text.contains("    - *Empty statement* *(see above)*"))
	}
}
