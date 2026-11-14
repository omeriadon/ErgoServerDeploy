//
//  CanvasLayoutTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 6/11/2026.
//

import ErgoLogic
import Foundation
import Testing

/// Layered layout and finding free space for one more box
struct CanvasLayoutTests {
	let id = ArgumentFixtures.id

	func rects(_ map: TestMap) -> [CanvasRect] {
		map.statements.map { CanvasRect(center: $0.position, size: CanvasLayout.boxSize) }
	}

	func noOverlaps(_ map: TestMap, margin: Double = 0, sourceLocation: SourceLocation = #_sourceLocation) {
		let boxes = rects(map)
		for (index, box) in boxes.enumerated() {
			for other in boxes[(index + 1)...] {
				#expect(!box.intersects(other, margin: margin), sourceLocation: sourceLocation)
			}
		}
	}

	/// Which row a box belongs to, whatever its jiggle
	func row(_ statement: ArgumentStatement) -> Int {
		Int(((statement.position.y - CanvasLayout.boxSize.height / 2) / CanvasLayout.rowPitch).rounded())
	}

	/// How many arrows run straight through a box they don't belong to
	func arrowsThroughBoxes(_ map: TestMap) -> Int {
		var hits = 0
		for link in map.links {
			guard let from = map.statement(link.premise)?.position, let to = map.statement(link.conclusion)?.position else { continue }
			let line = CanvasSegment(start: from, end: to)
			for statement in map.statements where statement.id != link.premise && statement.id != link.conclusion {
				let box = CanvasRect(center: statement.position, size: CanvasLayout.boxSize)
				let corners = [
					CanvasPoint(x: box.center.x - box.size.width / 2, y: box.center.y - box.size.height / 2),
					CanvasPoint(x: box.center.x + box.size.width / 2, y: box.center.y - box.size.height / 2),
					CanvasPoint(x: box.center.x - box.size.width / 2, y: box.center.y + box.size.height / 2),
					CanvasPoint(x: box.center.x + box.size.width / 2, y: box.center.y + box.size.height / 2),
				]
				let across = line.end - line.start
				let sides = corners.map { across.x * ($0.y - line.start.y) - across.y * ($0.x - line.start.x) }
				if sides.contains(where: { $0 < 0 }), sides.contains(where: { $0 > 0 }), statement.position.y > min(from.y, to.y), statement.position.y < max(from.y, to.y) {
					hits += 1
				}
			}
		}
		return hits
	}

	/// A deterministic spread of edges that only point forwards, so it is always acyclic
	func randomMap(count: Int, seed: UInt64) -> TestMap {
		var state = seed
		func next(_ bound: Int) -> Int {
			state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
			return Int((state >> 33) % UInt64(bound))
		}

		var links: [(Int, Int)] = []
		for conclusion in 2 ... count {
			for _ in 0 ..< 1 + next(3) {
				let premise = 1 + next(conclusion - 1)
				if !links.contains(where: { $0 == (premise, conclusion) }) {
					links.append((premise, conclusion))
				}
			}
		}
		return ArgumentFixtures.map(count, links: links)
	}

	@Test func emptyAndSingle() {
		#expect(CanvasLayout.positions(for: TestMap()).isEmpty)
		let single = CanvasLayout.arranged(ArgumentFixtures.map(1))
		#expect(single.statements[0].position == CanvasPoint(x: CanvasLayout.boxSize.width / 2, y: CanvasLayout.boxSize.height / 2))
	}

	@Test func premisesAreAboveTheirConclusion() throws {
		let map = CanvasLayout.arranged(ArgumentFixtures.map(5, links: [(1, 3), (2, 3), (3, 4), (1, 5)]))
		for link in map.links {
			let premise = try #require(map.statement(link.premise)?.position)
			let conclusion = try #require(map.statement(link.conclusion)?.position)
			#expect(premise.y < conclusion.y)
		}
	}

	@Test func layersAreTheLongestPathFromARoot() {
		// 1 → 2 → 3, and 1 → 3 directly: 3 is still two layers down
		let map = CanvasLayout.arranged(ArgumentFixtures.map(3, links: [(1, 2), (2, 3), (1, 3)]))
		#expect(map.statements.map(row) == [0, 1, 2])
	}

	@Test func aConclusionSitsBetweenItsPremises() {
		let map = CanvasLayout.arranged(ArgumentFixtures.map(3, links: [(1, 3), (2, 3)]))
		let x = map.statements.map(\.position.x)
		#expect(abs(x[2] - (x[0] + x[1]) / 2) <= 2 * CanvasLayout.jiggle)
	}

	@Test func diamondHasNoOverlap() {
		let map = CanvasLayout.arranged(ArgumentFixtures.map(4, links: [(1, 2), (1, 3), (2, 4), (3, 4)]))
		noOverlaps(map, margin: CanvasLayout.minimumGap)
		#expect(map.statements.map(row).sorted() == [0, 1, 1, 2])
	}

	@Test func unlinkedStatementsWrapIntoRows() {
		let map = CanvasLayout.arranged(ArgumentFixtures.map(CanvasLayout.maximumRowLength + 1))
		let rows = Dictionary(grouping: map.statements, by: row)
		#expect(rows.count == 2)
		#expect(rows.values.map(\.count).max() == CanvasLayout.maximumRowLength)
		noOverlaps(map, margin: CanvasLayout.minimumGap)
	}

	@Test func boxesSitOffAGridButTheSameWayEveryTime() {
		let row = CanvasLayout.arranged(ArgumentFixtures.map(CanvasLayout.maximumRowLength))
		#expect(Set(row.statements.map(\.position.y)).count > 1, "A row isn't ruled straight")
		#expect(CanvasLayout.positions(for: row) == CanvasLayout.positions(for: row))

		for seed in 1 ... 5 as ClosedRange<UInt64> {
			let map = CanvasLayout.arranged(randomMap(count: 20, seed: seed))
			for statement in map.statements {
				let steps = (statement.position.x - CanvasLayout.boxSize.width / 2) / (CanvasLayout.columnPitch / 2)
				let rows = (statement.position.y - CanvasLayout.boxSize.height / 2) / CanvasLayout.rowPitch
				#expect(abs(steps - steps.rounded()) * CanvasLayout.columnPitch / 2 <= 2 * CanvasLayout.jiggle)
				#expect(abs(rows - rows.rounded()) * CanvasLayout.rowPitch <= 2 * CanvasLayout.jiggle)
			}
		}
	}

	/// 1 → 2, 1 → 3, 3 → 4, 4 → 6, 5 → 6, 6 → 7: statement 5 has nothing above it, so it sits right above what it feeds
	@Test func aLonePremiseSitsRightAboveItsConclusion() {
		let map = CanvasLayout.arranged(ArgumentFixtures.map(7, links: [(1, 2), (1, 3), (3, 4), (4, 6), (5, 6), (6, 7)]))
		#expect(map.statements.map(row) == [0, 1, 1, 2, 2, 3, 4])
		#expect(arrowsThroughBoxes(map) == 0)
		noOverlaps(map, margin: CanvasLayout.minimumGap)

		// Forks open evenly, and a chain runs straight down
		let x = map.statements.map(\.position.x)
		#expect(abs(x[0] - (x[1] + x[2]) / 2) <= 2 * CanvasLayout.jiggle)
		#expect(abs(x[2] - x[3]) <= 2 * CanvasLayout.jiggle)
		#expect(abs(x[5] - (x[3] + x[4]) / 2) <= 2 * CanvasLayout.jiggle)
		#expect(abs(x[6] - x[5]) <= 2 * CanvasLayout.jiggle)
	}

	@Test func anArrowThatSkipsARowMissesTheBoxInBetween() {
		#expect(arrowsThroughBoxes(CanvasLayout.arranged(ArgumentFixtures.map(3, links: [(1, 2), (2, 3), (1, 3)]))) == 0)
		#expect(arrowsThroughBoxes(CanvasLayout.arranged(ArgumentFixtures.map(4, links: [(1, 2), (2, 3), (3, 4), (1, 4)]))) == 0)
		#expect(arrowsThroughBoxes(CanvasLayout.arranged(ArgumentFixtures.map(5, links: [(1, 2), (2, 3), (3, 5), (1, 4), (4, 5), (1, 5)]))) == 0)
	}

	@Test func aFewPremisesWrapWithoutArrowsThroughBoxes() {
		for count in 2 ... 6 {
			let map = CanvasLayout.arranged(ArgumentFixtures.map(count + 1, links: (1 ... count).map { ($0, count + 1) }))
			#expect(arrowsThroughBoxes(map) == 0, "\(count) premises")
		}
	}

	@Test func separateArgumentsGoAcross() throws {
		let map = CanvasLayout.arranged(ArgumentFixtures.map(7, links: [(1, 3), (2, 3), (4, 6), (5, 6)]))
		#expect(map.statements.map(row) == [0, 0, 1, 0, 0, 1, 0])
		noOverlaps(map, margin: CanvasLayout.minimumGap)

		let x = map.statements.map(\.position.x)
		#expect(try #require(x[0 ... 2].max()) < #require(x[3 ... 5].min()))
		#expect(try #require(x[3 ... 5].max()) < x[6], "Statement 7 links to nothing, so it goes last")
	}

	@Test func aWrappedLayerStaysAboveWhatItFeeds() throws {
		let map = CanvasLayout.arranged(ArgumentFixtures.map(8, links: (1 ..< 8).map { ($0, 8) }))
		noOverlaps(map, margin: CanvasLayout.minimumGap)
		let conclusion = try #require(map.statement(id(8))?.position.y)
		#expect(map.statements.dropLast().allSatisfy { $0.position.y < conclusion })
	}

	@Test func noOverlapUpToSixtyNodes() throws {
		for seed in 1 ... 20 as ClosedRange<UInt64> {
			for count in [2, 10, 30, 60] {
				let map = CanvasLayout.arranged(randomMap(count: count, seed: seed))
				noOverlaps(map, margin: CanvasLayout.minimumGap)
				#expect(map.statements.allSatisfy { $0.position.x >= CanvasLayout.boxSize.width / 2 && $0.position.y >= CanvasLayout.boxSize.height / 2 })
				for link in map.links {
					#expect(try #require(map.statement(link.premise)?.position.y) < #require(map.statement(link.conclusion)?.position.y))
				}
			}
		}
	}

	@Test func sixtyUnlinkedAndSixtyInAChain() {
		noOverlaps(CanvasLayout.arranged(ArgumentFixtures.map(60)))
		noOverlaps(CanvasLayout.arranged(ArgumentFixtures.map(60, links: (1 ..< 60).map { ($0, $0 + 1) })))
		let wide = CanvasLayout.arranged(ArgumentFixtures.map(60, links: (1 ..< 60).map { ($0, 60) }))
		noOverlaps(wide, margin: CanvasLayout.minimumGap)
	}

	@Test func layoutIsDeterministicAndIgnoresCurrentPositions() {
		let map = randomMap(count: 40, seed: 7)
		let first = CanvasLayout.arranged(map)
		#expect(CanvasLayout.arranged(map) == first)

		var shuffled = map
		for index in shuffled.statements.indices {
			shuffled.statements[index].position = CanvasPoint(x: Double(index * 37 % 11), y: Double(index * 13 % 7))
		}
		#expect(CanvasLayout.arranged(shuffled) == first, "Dragging boxes around doesn't change what auto layout gives")
		#expect(CanvasLayout.arranged(first) == first, "Laying out twice is the same as once")
	}

	@Test func layoutOnlyMovesBoxes() {
		let map = randomMap(count: 12, seed: 3)
		let arranged = CanvasLayout.arranged(map)
		#expect(arranged.links == map.links)
		#expect(arranged.statements.map(\.id) == map.statements.map(\.id))
	}

	@Test func cyclesStillGetALayout() {
		let map = CanvasLayout.arranged(ArgumentFixtures.map(4, links: [(1, 2), (2, 3), (3, 2), (3, 4)]))
		noOverlaps(map)
		#expect(map.statements.count == 4)
	}

	// MARK: - place

	@Test func placesPremisesAboveInLine() {
		let map = TestMap(statements: [ArgumentFixtures.statement(1, x: 1000, y: 200)])
		let spot = CanvasLayout.place(newNodeNear: id(1), in: map)
		#expect(spot == CanvasPoint(x: 1000, y: 200 - CanvasLayout.rowPitch))
		#expect(CanvasLayout.place(newNodeNear: id(1), in: map, side: .below) == CanvasPoint(x: 1000, y: 200 + CanvasLayout.rowPitch))
		#expect(CanvasLayout.place(newNodeNear: id(1), in: map, side: .beside) == CanvasPoint(x: 1000 + CanvasLayout.columnPitch, y: 200))
	}

	@Test func placeSkipsTakenSpots() {
		var map = TestMap(statements: [ArgumentFixtures.statement(1, x: 1000, y: 200)])
		var spots: [CanvasPoint] = []

		for number in 2 ... 30 {
			let spot = CanvasLayout.place(newNodeNear: id(1), in: map)
			spots.append(spot)
			map.statements.append(ArgumentFixtures.statement(number, x: spot.x, y: spot.y))
			noOverlaps(map, margin: CanvasLayout.minimumGap)
		}
		#expect(spots.first == CanvasPoint(x: 1000, y: 200 - CanvasLayout.rowPitch))
		#expect(spots[1].y == spots[0].y, "Fills the row next to it before moving out")
		#expect(spots.allSatisfy { $0.y < 200 })
	}

	@Test func placeWorksNextToLaidOutBoxes() {
		let map = CanvasLayout.arranged(ArgumentFixtures.map(3, links: [(1, 3), (2, 3)]))
		let spot = CanvasLayout.place(newNodeNear: id(3), in: map)
		var more = map
		more.statements.append(ArgumentFixtures.statement(4, x: spot.x, y: spot.y))
		noOverlaps(more, margin: CanvasLayout.minimumGap)
	}

	@Test func placeIsDeterministic() {
		let map = randomMap(count: 20, seed: 11)
		let laidOut = CanvasLayout.arranged(map)
		#expect(CanvasLayout.place(newNodeNear: id(5), in: laidOut) == CanvasLayout.place(newNodeNear: id(5), in: laidOut))
	}

	@Test func placeFallsBackWhenTheStatementIsMissing() {
		let spot = CanvasLayout.place(newNodeNear: id(9), in: TestMap())
		#expect(spot == CanvasPoint(x: 0, y: -CanvasLayout.rowPitch))
	}

	@Test func placeWorksInACrowd() {
		let map = CanvasLayout.arranged(ArgumentFixtures.map(60))
		let spot = CanvasLayout.place(newNodeNear: id(1), in: map)
		var more = map
		more.statements.append(ArgumentFixtures.statement(61, x: spot.x, y: spot.y))
		noOverlaps(more, margin: CanvasLayout.minimumGap)
	}
}
