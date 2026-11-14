//
//  CanvasGeometry.swift
//  ErgoKit
//
//  Created by Adon Omeri on 6/11/2026.
//

import Foundation

public struct CanvasSegment: Hashable, Codable, Sendable {
	public var start: CanvasPoint
	public var end: CanvasPoint

	public var length: Double {
		start.distance(to: end)
	}

	public init(start: CanvasPoint, end: CanvasPoint) {
		self.start = start
		self.end = end
	}
}

/// Pure maths for drawing arrows between boxes and for tapping them
public enum CanvasGeometry {
	/// Where the line from the centre of `rect` towards `point` crosses the box edge.
	/// The centre itself when `point` is the centre.
	public static func exit(of rect: CanvasRect, toward point: CanvasPoint) -> CanvasPoint {
		let direction = point - rect.center
		return rect.center + direction * edgeFraction(of: rect.size, along: direction)
	}

	/// The arrow between two boxes, leaving `source` and landing on the edge of `target`.
	/// Nil when the centres match or the boxes overlap so far that no line is left to draw.
	public static func arrow(from source: CanvasRect, to target: CanvasRect) -> CanvasSegment? {
		let direction = target.center - source.center
		guard direction != .zero else { return nil }

		let leaves = edgeFraction(of: source.size, along: direction)
		let enters = 1 - edgeFraction(of: target.size, along: direction)
		guard leaves < enters else { return nil }

		return CanvasSegment(start: source.center + direction * leaves, end: source.center + direction * enters)
	}

	/// How far a point is from the nearest point of the segment, for deciding which arrow a tap meant
	public static func distance(from point: CanvasPoint, to segment: CanvasSegment) -> Double {
		let line = segment.end - segment.start
		let lengthSquared = line.x * line.x + line.y * line.y
		guard lengthSquared > 0 else { return point.distance(to: segment.start) }

		let offset = point - segment.start
		let along = min(max((offset.x * line.x + offset.y * line.y) / lengthSquared, 0), 1)
		return point.distance(to: segment.start + line * along)
	}

	// MARK: - Curves

	/// The control point of a quadratic curve that lets the arrow hang down by `droop` times its length, like slack
	/// string, whichever way it points. An arrow pointing straight up or down has nothing to hang from, so it stays straight.
	public static func controlPoint(for segment: CanvasSegment, droop: Double = 0.1) -> CanvasPoint {
		let middle = segment.start + (segment.end - segment.start) * 0.5
		return middle + CanvasPoint(x: 0, y: segment.length * droop)
	}

	/// A point `t` of the way along the quadratic curve (0 is the start, 1 the end)
	public static func point(on segment: CanvasSegment, control: CanvasPoint, at t: Double) -> CanvasPoint {
		let rest = 1 - t
		return segment.start * (rest * rest) + control * (2 * rest * t) + segment.end * (t * t)
	}

	/// Distance to the curve, by checking a run of straight pieces along it. Close enough for a fingertip.
	public static func distance(from point: CanvasPoint, toCurve segment: CanvasSegment, control: CanvasPoint, pieces: Int = 24) -> Double {
		let pieces = max(pieces, 1)
		var nearest = Double.infinity
		var previous = segment.start

		for piece in 1 ... pieces {
			let next = Self.point(on: segment, control: control, at: Double(piece) / Double(pieces))
			nearest = min(nearest, distance(from: point, to: CanvasSegment(start: previous, end: next)))
			previous = next
		}

		return nearest
	}

	// MARK: - Helpers

	/// How much of `direction` it takes to get from the centre of a box to its edge
	private static func edgeFraction(of size: CanvasSize, along direction: CanvasPoint) -> Double {
		let horizontal = direction.x == 0 ? Double.infinity : size.width / 2 / abs(direction.x)
		let vertical = direction.y == 0 ? Double.infinity : size.height / 2 / abs(direction.y)
		let fraction = min(horizontal, vertical)
		return fraction.isFinite ? fraction : 0
	}
}
