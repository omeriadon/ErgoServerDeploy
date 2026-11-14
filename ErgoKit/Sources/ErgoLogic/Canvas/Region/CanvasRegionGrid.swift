//
//  CanvasRegionGrid.swift
//  Ergo
//
//  Created by Adon Omeri on 8/11/2026.
//

import Foundation

// MARK: - The grid

/// Distances on a grid, each new shape melted in where it's close to what's there. Each shape only touches the part of the
/// grid it can reach, so a big board costs what its cards do, and dragging one can do this every frame.
struct DistanceField {
	let step: Double
	let originX: Double
	let originY: Double
	let columns: Int
	let rows: Int
	var values: [Double]

	init(covering shapes: [Shape], step: Double, reachBeyond: Double) {
		let bounds = shapes.map { $0.bounds(extra: reachBeyond) }
		let minX = bounds.map(\.minX).min() ?? 0
		let maxX = bounds.map(\.maxX).max() ?? 0
		let minY = bounds.map(\.minY).min() ?? 0
		let maxY = bounds.map(\.maxY).max() ?? 0

		self.step = step
		originX = minX - step
		originY = minY - step
		columns = Int(((maxX - minX) / step).rounded(.up)) + 3
		rows = Int(((maxY - minY) / step).rounded(.up)) + 3
		values = Array(repeating: .greatestFiniteMagnitude, count: columns * rows)
	}

	/// A smooth minimum: the nearer of the two, and lower still where they're about equal, which is what closes gaps
	mutating func add(_ shape: Shape, melting melt: Double) {
		let bounds = shape.bounds(extra: melt)
		let firstColumn = max(Int(((bounds.minX - originX) / step).rounded(.down)), 0)
		let lastColumn = min(Int(((bounds.maxX - originX) / step).rounded(.up)), columns - 1)
		let firstRow = max(Int(((bounds.minY - originY) / step).rounded(.down)), 0)
		let lastRow = min(Int(((bounds.maxY - originY) / step).rounded(.up)), rows - 1)
		guard firstColumn <= lastColumn, firstRow <= lastRow else { return }

		for row in firstRow ... lastRow {
			let y = originY + Double(row) * step
			for column in firstColumn ... lastColumn {
				let new = shape.distance(from: CanvasPoint(x: originX + Double(column) * step, y: y))
				let index = row * columns + column
				let old = values[index]
				let closeness = max(melt - abs(old - new), 0) / melt
				values[index] = min(old, new) - closeness * closeness * melt / 4
			}
		}
	}

	/// The longest-reaching loop where the distance crosses zero. Anything inside it, like the pocket between two arrows,
	/// is another loop and isn't kept, so the region fills it.
	func largestContour() -> [CanvasPoint] {
		var neighbours: [Int: [Int]] = [:]
		neighbours.reserveCapacity(512)

		func connect(_ a: Int, _ b: Int) {
			neighbours[a, default: []].append(b)
			neighbours[b, default: []].append(a)
		}

		for row in 0 ..< rows - 1 {
			for column in 0 ..< columns - 1 {
				let shape = (value(column, row) < 0 ? 1 : 0)
					| (value(column + 1, row) < 0 ? 2 : 0)
					| (value(column + 1, row + 1) < 0 ? 4 : 0)
					| (value(column, row + 1) < 0 ? 8 : 0)
				guard shape != 0, shape != 15 else { continue }

				let top = edge(column, row, isVertical: false)
				let right = edge(column + 1, row, isVertical: true)
				let bottom = edge(column, row + 1, isVertical: false)
				let left = edge(column, row, isVertical: true)

				switch shape {
					case 1, 14: connect(left, top)
					case 2, 13: connect(top, right)
					case 3, 12: connect(left, right)
					case 4, 11: connect(right, bottom)
					case 6, 9: connect(top, bottom)
					case 7, 8: connect(left, bottom)
					case 5:
						connect(left, top)
						connect(right, bottom)
					case 10:
						connect(top, right)
						connect(left, bottom)
					default:
						break
				}
			}
		}

		var largest: [CanvasPoint] = []
		var largestArea = 0.0
		var visited: Set<Int> = []
		for start in neighbours.keys where !visited.contains(start) {
			var loop: [CanvasPoint] = []
			var previous: Int?
			var current = start
			while !visited.contains(current) {
				visited.insert(current)
				loop.append(crossing(on: current))
				let next = neighbours[current]?.first { $0 != previous && !visited.contains($0) }
				guard let next else { break }
				previous = current
				current = next
			}

			let area = Self.signedArea(of: loop)
			if abs(area) > largestArea {
				largestArea = abs(area)
				largest = area < 0 ? loop.reversed() : loop
			}
		}
		return largest
	}

	func value(_ column: Int, _ row: Int) -> Double {
		values[row * columns + column]
	}

	/// A grid edge's id: the corner it starts at, and which way it goes
	func edge(_ column: Int, _ row: Int, isVertical: Bool) -> Int {
		(row * columns + column) * 2 + (isVertical ? 1 : 0)
	}

	/// Where the distance reaches zero along a grid edge
	func crossing(on edge: Int) -> CanvasPoint {
		let isVertical = edge % 2 == 1
		let corner = edge / 2
		let row = corner / columns
		let column = corner % columns
		let start = value(column, row)
		let end = isVertical ? value(column, row + 1) : value(column + 1, row)
		let fraction = start == end ? 0.5 : start / (start - end)

		let x = originX + Double(column) * step
		let y = originY + Double(row) * step
		return isVertical
			? CanvasPoint(x: x, y: y + fraction * step)
			: CanvasPoint(x: x + fraction * step, y: y)
	}

	static func signedArea(of loop: [CanvasPoint]) -> Double {
		var area = 0.0
		for (index, point) in loop.enumerated() {
			let next = loop[(index + 1) % loop.count]
			area += point.x * next.y - next.x * point.y
		}
		return area / 2
	}
}
