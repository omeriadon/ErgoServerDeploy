//
//  CanvasRegionTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 7/11/2026.
//

import ErgoLogic
import Foundation
import Testing

/// The shape around a source, its cards and their arrows, and which region a card ends up in
struct CanvasRegionTests {
	private let source = CanvasPoint(x: 0, y: 0)
	private let premises = [CanvasPoint(x: -300, y: 300), CanvasPoint(x: 300, y: 300)]
	private let conclusion = CanvasPoint(x: 0, y: 516)
	private let box = CanvasLayout.boxSize

	private var members: [CanvasPoint] {
		premises + [conclusion]
	}

	private var arrows: [CanvasRegion.Arrow] {
		premises.map { CanvasRegion.Arrow(from: $0, to: conclusion) }
	}

	@Test func everyCardIsInside() {
		let outline = CanvasRegion.outline(source: source, members: members, arrows: arrows)
		for member in members {
			for corner in corners(of: member) {
				#expect(CanvasRegion.contains(corner, in: outline))
			}
		}
	}

	@Test func theSourceSitsOnTheEdge() {
		let outline = CanvasRegion.outline(source: source, members: members, arrows: arrows)
		#expect(CanvasRegion.contains(CanvasPoint(x: 0, y: box.height / 2), in: outline))
		#expect(!CanvasRegion.contains(CanvasPoint(x: 0, y: -box.height / 2), in: outline))
	}

	@Test func theEdgeGoesInWhereThereIsNothing() {
		// An L: the empty corner would be inside anything convex
		let outline = CanvasRegion.outline(
			source: source,
			members: [CanvasPoint(x: 0, y: 240), CanvasPoint(x: 600, y: 240)],
			arrows: [CanvasRegion.Arrow(from: CanvasPoint(x: 0, y: 240), to: CanvasPoint(x: 600, y: 240))]
		)
		#expect(!CanvasRegion.contains(CanvasPoint(x: 500, y: 100), in: outline))
	}

	@Test func itFollowsAnArrow() throws {
		let far = CanvasPoint(x: 900, y: 900)
		let start = CanvasPoint(x: 0, y: 240)
		let outline = CanvasRegion.outline(source: source, members: [start, far], arrows: [CanvasRegion.Arrow(from: start, to: far)])

		let line = try #require(CanvasGeometry.arrow(from: CanvasRect(center: start, size: box), to: CanvasRect(center: far, size: box)))
		let control = CanvasGeometry.controlPoint(for: line)
		for step in 0 ... 10 {
			#expect(CanvasRegion.contains(CanvasGeometry.point(on: line, control: control, at: Double(step) / 10), in: outline))
		}
	}

	@Test func aThinGapBetweenStackedCardsCloses() {
		let top = CanvasPoint(x: 0, y: 240)
		let bottom = CanvasPoint(x: 0, y: 456)
		let outline = CanvasRegion.outline(source: source, members: [top, bottom], arrows: [CanvasRegion.Arrow(from: top, to: bottom)])
		#expect(CanvasRegion.contains(CanvasPoint(x: -110, y: 348), in: outline))
	}

	@Test func aPocketBetweenArrowsIsFilled() {
		// Two arrows from one card to another by way of a third leave a hole in the middle
		let top = CanvasPoint(x: 0, y: 240)
		let left = CanvasPoint(x: -700, y: 700)
		let right = CanvasPoint(x: 700, y: 700)
		let bottom = CanvasPoint(x: 0, y: 1160)
		let outline = CanvasRegion.outline(source: source, members: [top, left, right, bottom], arrows: [
			CanvasRegion.Arrow(from: top, to: left), CanvasRegion.Arrow(from: top, to: right),
			CanvasRegion.Arrow(from: left, to: bottom), CanvasRegion.Arrow(from: right, to: bottom),
		])
		#expect(CanvasRegion.contains(CanvasPoint(x: 0, y: 700), in: outline))
	}

	@Test func aCardWithNoArrowsIsStillJoinedOn() {
		let far = CanvasPoint(x: 2000, y: 300)
		let outline = CanvasRegion.outline(source: source, members: [far])
		#expect(CanvasRegion.contains(far, in: outline))
		#expect(CanvasRegion.contains(CanvasPoint(x: 0, y: box.height / 2), in: outline))
	}

	@Test func theSameNumberOfPointsEveryTime() {
		let small = CanvasRegion.outline(source: source, members: [])
		let big = CanvasRegion.outline(source: source, members: members, arrows: arrows)
		#expect(small.count == CanvasRegion.outlinePoints)
		#expect(big.count == CanvasRegion.outlinePoints)
	}

	@Test func theSameWayRoundEveryTime() {
		func area(_ outline: [CanvasPoint]) -> Double {
			outline.indices.reduce(0) { total, index in
				let next = outline[(index + 1) % outline.count]
				return total + outline[index].x * next.y - next.x * outline[index].y
			}
		}
		#expect(area(CanvasRegion.outline(source: source, members: [])) > 0)
		#expect(area(CanvasRegion.outline(source: source, members: members, arrows: arrows)) > 0)
	}

	@Test func theSourceGoesAboveItsCardsWithoutTouching() throws {
		let position = try #require(CanvasRegion.sourcePosition(above: members))
		#expect(position.x == 0)
		#expect(position.y + box.height / 2 < 300 - box.height / 2)
		#expect(CanvasRegion.sourcePosition(above: []) == nil)
	}

	@Test func distanceIsZeroInsideAndGrowsOutside() {
		let outline = CanvasRegion.outline(source: source, members: [conclusion])
		#expect(CanvasRegion.distance(from: conclusion, to: outline) == 0)
		let near = CanvasRegion.distance(from: CanvasPoint(x: 0, y: 800), to: outline)
		let far = CanvasRegion.distance(from: CanvasPoint(x: 0, y: 1200), to: outline)
		#expect(near > 0)
		#expect(far > near)
	}

	// MARK: - Home

	@Test func aCardStaysWhileItIsClose() {
		let id = UUID()
		let outlines = [id: CanvasRegion.outline(source: source, members: premises)]
		#expect(CanvasRegion.home(of: conclusion, current: id, outlines: outlines) == id)
	}

	@Test func aCardDraggedFarAwayLeaves() {
		let id = UUID()
		let outlines = [id: CanvasRegion.outline(source: source, members: premises)]
		#expect(CanvasRegion.home(of: CanvasPoint(x: 3000, y: 3000), current: id, outlines: outlines) == nil)
	}

	@Test func aCardDroppedInsideARegionJoinsIt() {
		let id = UUID()
		let outlines = [id: CanvasRegion.outline(source: source, members: members, arrows: arrows)]
		#expect(CanvasRegion.home(of: premises[0], current: nil, outlines: outlines) == id)
		#expect(CanvasRegion.home(of: CanvasPoint(x: 3000, y: 0), current: nil, outlines: outlines) == nil)
	}

	@Test func aCardDroppedInsideAnotherRegionMoves() {
		let old = UUID()
		let new = UUID()
		let outlines = [
			old: CanvasRegion.outline(source: source, members: premises),
			new: CanvasRegion.outline(source: CanvasPoint(x: 3000, y: 0), members: [CanvasPoint(x: 3000, y: 300)]),
		]
		#expect(CanvasRegion.home(of: CanvasPoint(x: 3000, y: 300), current: old, outlines: outlines) == new)
	}

	@Test func aRegionThatIsGoneIsNoHome() {
		#expect(CanvasRegion.home(of: .zero, current: UUID(), outlines: [:]) == nil)
	}

	private func corners(of center: CanvasPoint) -> [CanvasPoint] {
		let rect = CanvasRect(center: center, size: box)
		return [
			CanvasPoint(x: rect.minX, y: rect.minY), CanvasPoint(x: rect.maxX, y: rect.minY),
			CanvasPoint(x: rect.minX, y: rect.maxY), CanvasPoint(x: rect.maxX, y: rect.maxY),
		]
	}
}
