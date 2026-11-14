//
//  CanvasGeometryTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 6/11/2026.
//

import ErgoLogic
import Foundation
import Testing

/// Arrow ends, tap distances and curves
struct CanvasGeometryTests {
	let size = CanvasSize(width: 200, height: 100)

	func box(_ x: Double, _ y: Double) -> CanvasRect {
		CanvasRect(center: CanvasPoint(x: x, y: y), size: size)
	}

	func expectClose(_ a: CanvasPoint, _ b: CanvasPoint, sourceLocation: SourceLocation = #_sourceLocation) {
		#expect(a.distance(to: b) < 1e-9, "\(a) is not \(b)", sourceLocation: sourceLocation)
	}

	@Test func exitsThroughTheNearestEdge() {
		let rect = box(0, 0)
		expectClose(CanvasGeometry.exit(of: rect, toward: CanvasPoint(x: 1000, y: 0)), CanvasPoint(x: 100, y: 0))
		expectClose(CanvasGeometry.exit(of: rect, toward: CanvasPoint(x: -1000, y: 0)), CanvasPoint(x: -100, y: 0))
		expectClose(CanvasGeometry.exit(of: rect, toward: CanvasPoint(x: 0, y: 700)), CanvasPoint(x: 0, y: 50))
		expectClose(CanvasGeometry.exit(of: rect, toward: CanvasPoint(x: 0, y: -7)), CanvasPoint(x: 0, y: -50))
	}

	@Test func exitsThroughASideOrACornerDependingOnTheAngle() {
		let rect = box(0, 0)
		// Wide angle leaves through the right edge
		expectClose(CanvasGeometry.exit(of: rect, toward: CanvasPoint(x: 400, y: 100)), CanvasPoint(x: 100, y: 25))
		// Steep angle leaves through the bottom
		expectClose(CanvasGeometry.exit(of: rect, toward: CanvasPoint(x: 100, y: 400)), CanvasPoint(x: 12.5, y: 50))
		// Exactly the diagonal of a 2:1 box hits the corner
		expectClose(CanvasGeometry.exit(of: rect, toward: CanvasPoint(x: 200, y: 100)), CanvasPoint(x: 100, y: 50))
	}

	@Test func exitsStayOnTheBoxEdge() {
		let rect = box(300, -40)
		for degrees in stride(from: 0.0, to: 360.0, by: 7.0) {
			let radians = degrees * .pi / 180
			let target = CanvasPoint(x: 300 + 900 * cos(radians), y: -40 + 900 * sin(radians))
			let edge = CanvasGeometry.exit(of: rect, toward: target)
			let onVertical = abs(abs(edge.x - 300) - 100) < 1e-6 && abs(edge.y + 40) <= 50 + 1e-6
			let onHorizontal = abs(abs(edge.y + 40) - 50) < 1e-6 && abs(edge.x - 300) <= 100 + 1e-6
			#expect(onVertical || onHorizontal, "Angle \(degrees): \(edge)")
		}
	}

	@Test func exitTowardTheCentreIsTheCentre() {
		expectClose(CanvasGeometry.exit(of: box(5, 5), toward: CanvasPoint(x: 5, y: 5)), CanvasPoint(x: 5, y: 5))
	}

	@Test func arrowRunsEdgeToEdge() throws {
		let arrow = try #require(CanvasGeometry.arrow(from: box(0, 0), to: box(500, 0)))
		expectClose(arrow.start, CanvasPoint(x: 100, y: 0))
		expectClose(arrow.end, CanvasPoint(x: 400, y: 0))
		#expect(abs(arrow.length - 300) < 1e-9)

		let down = try #require(CanvasGeometry.arrow(from: box(0, 0), to: box(0, 300)))
		expectClose(down.start, CanvasPoint(x: 0, y: 50))
		expectClose(down.end, CanvasPoint(x: 0, y: 250))
	}

	@Test func arrowsFollowTheCentreToCentreLine() throws {
		let arrow = try #require(CanvasGeometry.arrow(from: box(0, 0), to: box(600, 300)))
		// Both ends are on the line y = x / 2
		#expect(abs(arrow.start.y - arrow.start.x / 2) < 1e-9)
		#expect(abs(arrow.end.y - arrow.end.x / 2) < 1e-9)
		#expect(!box(0, 0).contains(CanvasPoint(x: arrow.start.x + 0.01, y: arrow.start.y + 0.005)) || arrow.start.x <= 100)
	}

	@Test func arrowsBetweenDifferentSizes() throws {
		let small = CanvasRect(center: .zero, size: CanvasSize(width: 20, height: 20))
		let arrow = try #require(CanvasGeometry.arrow(from: small, to: box(300, 0)))
		expectClose(arrow.start, CanvasPoint(x: 10, y: 0))
		expectClose(arrow.end, CanvasPoint(x: 200, y: 0))
	}

	@Test func noArrowWhenBoxesOverlapOrCoincide() {
		#expect(CanvasGeometry.arrow(from: box(0, 0), to: box(0, 0)) == nil)
		#expect(CanvasGeometry.arrow(from: box(0, 0), to: box(150, 0)) == nil)
		#expect(CanvasGeometry.arrow(from: box(0, 0), to: box(200, 0)) == nil, "Touching boxes have no room for an arrow")
		#expect(CanvasGeometry.arrow(from: box(0, 0), to: box(210, 0)) != nil)
	}

	@Test func distanceToASegment() {
		let segment = CanvasSegment(start: CanvasPoint(x: 0, y: 0), end: CanvasPoint(x: 100, y: 0))
		#expect(CanvasGeometry.distance(from: CanvasPoint(x: 50, y: 30), to: segment) == 30)
		#expect(CanvasGeometry.distance(from: CanvasPoint(x: 50, y: 0), to: segment) == 0)
		#expect(CanvasGeometry.distance(from: CanvasPoint(x: -30, y: 40), to: segment) == 50, "Beyond the start it is the distance to the start")
		#expect(CanvasGeometry.distance(from: CanvasPoint(x: 130, y: 40), to: segment) == 50)
	}

	@Test func distanceToADiagonalSegment() {
		let segment = CanvasSegment(start: CanvasPoint(x: 0, y: 0), end: CanvasPoint(x: 100, y: 100))
		#expect(abs(CanvasGeometry.distance(from: CanvasPoint(x: 100, y: 0), to: segment) - 100 / 2.0.squareRoot()) < 1e-9)
	}

	@Test func distanceToAPointShapedSegment() {
		let segment = CanvasSegment(start: CanvasPoint(x: 5, y: 5), end: CanvasPoint(x: 5, y: 5))
		#expect(CanvasGeometry.distance(from: CanvasPoint(x: 8, y: 9), to: segment) == 5)
	}

	@Test func controlPointHangsDownEitherWay() {
		let segment = CanvasSegment(start: CanvasPoint(x: 0, y: 0), end: CanvasPoint(x: 100, y: 0))
		expectClose(CanvasGeometry.controlPoint(for: segment, droop: 0.1), CanvasPoint(x: 50, y: 10))
		expectClose(CanvasGeometry.controlPoint(for: segment, droop: 0), CanvasPoint(x: 50, y: 0))

		let back = CanvasSegment(start: segment.end, end: segment.start)
		expectClose(CanvasGeometry.controlPoint(for: back, droop: 0.1), CanvasPoint(x: 50, y: 10))

		let upright = CanvasSegment(start: CanvasPoint(x: 0, y: 0), end: CanvasPoint(x: 0, y: 100))
		#expect(CanvasGeometry.controlPoint(for: upright).x == 0, "An upright arrow stays straight")
	}

	@Test func curvePointsRunFromStartToEnd() {
		let segment = CanvasSegment(start: CanvasPoint(x: 0, y: 0), end: CanvasPoint(x: 100, y: 0))
		let control = CanvasGeometry.controlPoint(for: segment)
		expectClose(CanvasGeometry.point(on: segment, control: control, at: 0), segment.start)
		expectClose(CanvasGeometry.point(on: segment, control: control, at: 1), segment.end)
		expectClose(CanvasGeometry.point(on: segment, control: control, at: 0.5), CanvasPoint(x: 50, y: 5))
	}

	@Test func distanceToACurve() {
		let segment = CanvasSegment(start: CanvasPoint(x: 0, y: 0), end: CanvasPoint(x: 100, y: 0))
		let control = CanvasGeometry.controlPoint(for: segment)
		#expect(CanvasGeometry.distance(from: CanvasPoint(x: 50, y: 5), toCurve: segment, control: control) < 0.1)
		#expect(CanvasGeometry.distance(from: CanvasPoint(x: 50, y: 0), toCurve: segment, control: control) > 4, "The straight line is off the curve")
		#expect(CanvasGeometry.distance(from: CanvasPoint(x: 50, y: -40), toCurve: segment, control: control) > 25)
	}

	@Test func rectBasics() {
		let rect = box(10, 20)
		#expect(rect.minX == -90 && rect.maxX == 110 && rect.minY == -30 && rect.maxY == 70)
		#expect(rect.contains(CanvasPoint(x: 10, y: 20)))
		#expect(rect.contains(CanvasPoint(x: 110, y: 70)), "The edge is inside")
		#expect(!rect.contains(CanvasPoint(x: 111, y: 20)))
		#expect(!box(0, 0).intersects(box(200, 0)), "Touching isn't overlapping")
		#expect(box(0, 0).intersects(box(199, 0)))
		#expect(box(0, 0).intersects(box(210, 0), margin: 20))
	}

	@Test func canvasValuesRoundTripThroughCodable() throws {
		let rect = box(1.5, -2)
		let decoded = try JSONDecoder().decode(CanvasRect.self, from: JSONEncoder().encode(rect))
		#expect(decoded == rect)
		let statement = ArgumentFixtures.statement(1, english: "If X, Y", x: 3, y: 4)
		#expect(try JSONDecoder().decode(ArgumentStatement.self, from: JSONEncoder().encode(statement)) == statement)
	}
}
