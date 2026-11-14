//
//  CanvasRegion.swift
//  ErgoKit
//
//  Created by Adon Omeri on 7/11/2026.
//

import Foundation

/// The shape around a source and the cards made from it. It's worked out from where they are and never stored, so it
/// follows them as they move.
///
/// The shape hugs what's there: a band around each card and along each arrow, melted together where they come close, so
/// it goes in wherever the arrangement leaves a gap. It's found by measuring, at each point of a grid, how far the nearest
/// card or arrow is, and tracing where that distance reaches the band's edge. Only the lower half of the source counts,
/// so the source sits on the edge.
public enum CanvasRegion {
	/// An arrow between two cards of a region
	public struct Arrow: Hashable, Sendable {
		public var from: CanvasPoint
		public var to: CanvasPoint

		public init(from: CanvasPoint, to: CanvasPoint) {
			self.from = from
			self.to = to
		}
	}

	/// Room between a card and the edge
	public static let padding = 34.0

	/// Every outline has this many points, evenly spaced, so one shape can always slide into another
	public static let outlinePoints = 240

	/// A card dropped further than this from the rest of its region leaves it. Far enough that a card already at the far
	/// end doesn't leave, since the region's outline without it stops a whole row short.
	public static let leaveDistance = CanvasLayout.boxSize.height + CanvasLayout.rowGap + padding

	/// How far the band reaches either side of an arrow
	static let arrowReach = 24.0

	/// A gap between two bands melts shut if it's under half of this, which closes the slit either side of an arrow between
	/// stacked cards (the row gap less a padding each side, 52). Rounds the inside corners where bands meet too.
	static let melt = 110.0

	/// Canvas units between the points measured. The edge is placed between them, so it's finer than this.
	static let gridStep = 12.0

	/// How many straight pieces an arrow's curve is measured as
	static let arrowPieces = 6

	// MARK: - Outline

	/// The points round the edge, the same way round every time. A card with no arrow to the rest is joined on by the
	/// shortest way, so a region is always one piece.
	public static func outline(source: CanvasPoint, members: [CanvasPoint], arrows: [Arrow] = []) -> [CanvasPoint] {
		let size = CanvasLayout.boxSize
		let top = source.y + padding
		var shapes: [Shape] = [
			.box(
				minX: source.x - size.width / 2,
				maxX: source.x + size.width / 2,
				minY: min(top, source.y + size.height / 2),
				maxY: source.y + size.height / 2,
				reach: padding
			),
		]
		for member in members {
			let box = CanvasRect(center: member, size: size)
			shapes.append(.box(minX: box.minX, maxX: box.maxX, minY: box.minY, maxY: box.maxY, reach: padding))
		}
		for arrow in arrows {
			if let line = line(along: arrow) {
				shapes.append(.line(line, reach: arrowReach))
			}
		}
		for join in joins(source: source, members: members, arrows: arrows) {
			shapes.append(.line(join, reach: arrowReach))
		}

		let field = DistanceField(covering: shapes, step: gridStep, reachBeyond: melt)
		var measured = field
		for shape in shapes {
			measured.add(shape, melting: melt)
		}
		return resampled(measured.largestContour())
	}

	/// Where a source goes to sit on the top edge of `members`, centred over them
	public static func sourcePosition(above members: [CanvasPoint]) -> CanvasPoint? {
		guard let left = members.map(\.x).min(), let right = members.map(\.x).max(), let top = members.map(\.y).min() else { return nil }
		let height = CanvasLayout.boxSize.height
		return CanvasPoint(x: (left + right) / 2, y: top - height - padding)
	}

	// MARK: - Inside

	public static func contains(_ point: CanvasPoint, in outline: [CanvasPoint]) -> Bool {
		guard outline.count >= 3 else { return false }
		var isInside = false
		var previous = outline[outline.count - 1]
		for current in outline {
			if (current.y > point.y) != (previous.y > point.y) {
				let crossing = previous.x + (point.y - previous.y) / (current.y - previous.y) * (current.x - previous.x)
				if point.x < crossing {
					isInside.toggle()
				}
			}
			previous = current
		}
		return isInside
	}

	/// How far `point` is from the region. Zero inside it.
	public static func distance(from point: CanvasPoint, to outline: [CanvasPoint]) -> Double {
		if contains(point, in: outline) {
			return 0
		}
		var nearest = Double.infinity
		for (index, start) in outline.enumerated() {
			let segment = CanvasSegment(start: start, end: outline[(index + 1) % outline.count])
			nearest = min(nearest, CanvasGeometry.distance(from: point, to: segment))
		}
		return nearest
	}

	/// The region a card belongs to after being put down at `point`: one it's inside, its old one first, or else its old
	/// one while it's still close, or else none. `outlines` are worked out without the card, ids sorted so every device agrees.
	public static func home(of point: CanvasPoint, current: UUID?, outlines: [UUID: [CanvasPoint]]) -> UUID? {
		if let current, let outline = outlines[current], contains(point, in: outline) {
			return current
		}
		let inside = outlines.keys
			.sorted { $0.uuidString < $1.uuidString }
			.first { contains(point, in: outlines[$0] ?? []) }
		if let inside {
			return inside
		}
		if let current, let outline = outlines[current], distance(from: point, to: outline) <= leaveDistance {
			return current
		}
		return nil
	}

	// MARK: - What the band goes around

	/// The arrow's curve, the one that's drawn, as straight pieces
	static func line(along arrow: Arrow) -> [CanvasPoint]? {
		let size = CanvasLayout.boxSize
		guard let segment = CanvasGeometry.arrow(from: CanvasRect(center: arrow.from, size: size), to: CanvasRect(center: arrow.to, size: size)) else { return nil }
		let control = CanvasGeometry.controlPoint(for: segment)
		return (0 ... arrowPieces).map { CanvasGeometry.point(on: segment, control: control, at: Double($0) / Double(arrowPieces)) }
	}

	/// Straight lines joining what arrows leave apart, nearest pairs first, so nothing floats off on its own. The first
	/// point stands for the source, at its bottom edge, since that's the half in the region.
	static func joins(source: CanvasPoint, members: [CanvasPoint], arrows: [Arrow]) -> [[CanvasPoint]] {
		let points = [source + CanvasPoint(x: 0, y: CanvasLayout.boxSize.height / 2)] + members
		var group = Array(points.indices)

		func root(_ index: Int) -> Int {
			var index = index
			while group[index] != index {
				index = group[index]
			}
			return index
		}

		for arrow in arrows {
			guard let from = members.firstIndex(of: arrow.from), let to = members.firstIndex(of: arrow.to) else { continue }
			group[root(from + 1)] = root(to + 1)
		}

		var pairs: [(a: Int, b: Int, distance: Double)] = []
		for a in points.indices {
			for b in points.indices where b > a {
				pairs.append((a, b, points[a].distance(to: points[b])))
			}
		}
		pairs.sort { ($0.distance, $0.a, $0.b) < ($1.distance, $1.a, $1.b) }

		var lines: [[CanvasPoint]] = []
		for pair in pairs where root(pair.a) != root(pair.b) {
			group[root(pair.a)] = root(pair.b)
			lines.append([points[pair.a], points[pair.b]])
		}
		return lines
	}

	// MARK: - Spacing

	/// Evenly spaced along the edge, starting nearest the top left so one outline's points line up with the next one's
	static func resampled(_ contour: [CanvasPoint]) -> [CanvasPoint] {
		guard contour.count >= 3 else { return contour }

		let lowest = contour.min { ($0.x + $0.y) < ($1.x + $1.y) } ?? contour[0]
		let start = contour.firstIndex(of: lowest) ?? 0
		let ring = Array(contour[start...] + contour[..<start]) + [lowest]

		var total = 0.0
		for index in 1 ..< ring.count {
			total += ring[index - 1].distance(to: ring[index])
		}
		guard total > 0 else { return contour }

		let spacing = total / Double(outlinePoints)
		var points: [CanvasPoint] = []
		var walked = 0.0
		var piece = 1
		for count in 0 ..< outlinePoints {
			let wanted = spacing * Double(count)
			while piece < ring.count - 1, walked + ring[piece - 1].distance(to: ring[piece]) < wanted {
				walked += ring[piece - 1].distance(to: ring[piece])
				piece += 1
			}
			let length = ring[piece - 1].distance(to: ring[piece])
			let fraction = length > 0 ? (wanted - walked) / length : 0
			points.append(ring[piece - 1] + (ring[piece] - ring[piece - 1]) * fraction)
		}
		return points
	}
}

// MARK: - Shapes

enum Shape {
	case box(minX: Double, maxX: Double, minY: Double, maxY: Double, reach: Double)
	case line([CanvasPoint], reach: Double)

	/// Everything within `extra` of the band
	func bounds(extra: Double) -> (minX: Double, maxX: Double, minY: Double, maxY: Double) {
		switch self {
			case let .box(minX, maxX, minY, maxY, reach):
				return (minX - reach - extra, maxX + reach + extra, minY - reach - extra, maxY + reach + extra)
			case let .line(points, reach):
				let xs = points.map(\.x)
				let ys = points.map(\.y)
				let around = reach + extra
				return ((xs.min() ?? 0) - around, (xs.max() ?? 0) + around, (ys.min() ?? 0) - around, (ys.max() ?? 0) + around)
		}
	}

	/// How far `point` is from the band's edge, negative inside it
	func distance(from point: CanvasPoint) -> Double {
		switch self {
			case let .box(minX, maxX, minY, maxY, reach):
				let dx = max(minX - point.x, point.x - maxX, 0)
				let dy = max(minY - point.y, point.y - maxY, 0)
				if dx > 0 || dy > 0 {
					return hypot(dx, dy) - reach
				}
				return -min(point.x - minX, maxX - point.x, point.y - minY, maxY - point.y) - reach

			case let .line(points, reach):
				var nearest = Double.infinity
				for index in 1 ..< points.count {
					let segment = CanvasSegment(start: points[index - 1], end: points[index])
					nearest = min(nearest, CanvasGeometry.distance(from: point, to: segment))
				}
				return nearest - reach
		}
	}
}
