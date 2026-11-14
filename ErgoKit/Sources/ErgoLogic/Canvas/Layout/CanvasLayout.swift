//
//  CanvasLayout.swift
//  ErgoKit
//
//  Created by Adon Omeri on 6/11/2026.
//

import Foundation

/// Where boxes go. Layers run top to bottom, with premises above their conclusion, and each statement sits as close as
/// it can to what it's linked to, so arrows stay short. A layer too wide for a phone wraps onto more rows.
///
/// Rows are a fixed `rowPitch` apart and boxes sit on half-column steps, so every arrow between neighbouring rows is
/// straight down or at nearly one of a few angles. Arrows can't bend, so boxes keep out of the way of any arrow that skips
/// a row. Each box then sits a little off its spot so it doesn't look like a spreadsheet. The gaps are wider than that
/// `jiggle`, so it can't make boxes overlap or put one on an arrow.
///
/// Nothing here looks at current positions, and each box's jiggle comes from its id, so the same map always gives the
/// same layout on every device.
public enum CanvasLayout {
	/// The box the layout assumes. The app draws boxes this size so nothing overlaps.
	public static let boxSize = CanvasSize(width: 220, height: 96)

	public static let columnGap = 80.0

	/// Roomier than `columnGap`, since this is where the arrows between layers run
	public static let rowGap = 120.0

	/// Boxes dropped by `place` keep at least this much clear space from their neighbours
	public static let minimumGap = 24.0

	/// The furthest a laid out box sits from its spot, along each axis. Two neighbours leaning towards each other
	/// still keep `minimumGap` between them.
	public static let jiggle = 20.0

	/// The most boxes side by side in one row
	public static let maximumRowLength = 3

	public static var columnPitch: Double {
		boxSize.width + columnGap
	}

	public static var rowPitch: Double {
		boxSize.height + rowGap
	}

	// MARK: - Auto layout

	/// New centres for every statement, with the top left box edge at (0, 0). Unlinked arguments sit side by side, tops
	/// level, and statements with no links at all go last as a plain grid.
	public static func positions(for map: ArgumentMap<some Any, some Any>) -> [UUID: CanvasPoint] {
		let order = map.topologicalOrder(tieBreak: .listing)
		let graph = LayeredGraph(order: order, links: map.links.map { ($0.premise, $0.conclusion) })

		var spots: [UUID: CanvasPoint] = [:]
		var groupLeft = 0.0
		for group in graph.groups {
			let rows = graph.rows(of: group)
			let across = graph.columns(for: rows)

			let xs = group.map { across[$0] }
			let left = xs.min() ?? 0
			for (index, row) in rows.enumerated() {
				for statement in row {
					let id = order[statement]
					spots[id] = CanvasPoint(x: across[statement] - left + groupLeft, y: Double(index) * rowPitch) + offset(of: id)
				}
			}

			// Half a column more than neighbours get, so separate arguments read as separate, and still on the grid
			groupLeft += (xs.max() ?? 0) - left + columnPitch * 1.5
		}

		let left = spots.values.map(\.x).min() ?? 0
		let top = spots.values.map(\.y).min() ?? 0
		return spots.mapValues { CanvasPoint(x: $0.x - left + boxSize.width / 2, y: $0.y - top + boxSize.height / 2) }
	}

	/// How far off its spot this box sits. Hashed by hand, since `hashValue` changes every launch and this has to come out
	/// the same on every device.
	static func offset(of id: UUID) -> CanvasPoint {
		var hash: UInt64 = 0xCBF2_9CE4_8422_2325
		withUnsafeBytes(of: id.uuid) { bytes in
			for byte in bytes {
				hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3
			}
		}
		hash = (hash ^ (hash >> 29)) &* 0xBF58_476D_1CE4_E5B9
		hash ^= hash >> 32

		func amount(_ bits: UInt64) -> Double {
			((Double(bits & 0xFFFF) / 0xFFFF * 2 - 1) * jiggle).rounded()
		}
		return CanvasPoint(x: amount(hash), y: amount(hash >> 16))
	}

	/// The map with every statement moved to its laid out position
	public static func arranged<Node, Link>(_ map: ArgumentMap<Node, Link>) -> ArgumentMap<Node, Link> {
		let positions = positions(for: map)
		var map = map
		for index in map.statements.indices {
			if let position = positions[map.statements[index].id] {
				map.statements[index].position = position
			}
		}
		return map
	}

	// MARK: - Placing one box

	public enum Side: Sendable {
		/// Where a premise goes
		case above
		/// Where a conclusion goes
		case below
		/// Where a sibling goes
		case beside
	}

	/// A free spot beside the statement `id`, nearest first. Falls back to beside the origin when `id` isn't in the map.
	public static func place(newNodeNear id: UUID, in map: ArgumentMap<some Any, some Any>, side: Side = .above) -> CanvasPoint {
		place(near: map.statement(id)?.position ?? .zero, side: side, occupied: map.statements.map(\.position))
	}

	/// Tries the row (or column, for `.beside`) next to `anchor` directly in line with it, then alternately further along either way,
	/// then moves a row further out. There are only so many boxes, so a free spot turns up eventually.
	public static func place(near anchor: CanvasPoint, side: Side, occupied: [CanvasPoint]) -> CanvasPoint {
		let steps: (primary: CanvasPoint, secondary: CanvasPoint) = switch side {
			case .above: (CanvasPoint(x: 0, y: -rowPitch), CanvasPoint(x: columnPitch, y: 0))
			case .below: (CanvasPoint(x: 0, y: rowPitch), CanvasPoint(x: columnPitch, y: 0))
			case .beside: (CanvasPoint(x: columnPitch, y: 0), CanvasPoint(x: 0, y: rowPitch))
		}

		func isFree(_ candidate: CanvasPoint) -> Bool {
			let box = CanvasRect(center: candidate, size: boxSize)
			return !occupied.contains { box.intersects(CanvasRect(center: $0, size: boxSize), margin: minimumGap) }
		}

		let limit = occupied.count + 1
		for distance in 1 ... 2 * limit {
			let base = anchor + steps.primary * Double(distance)
			for offset in 0 ... limit {
				for direction in offset == 0 ? [1.0] : [1.0, -1.0] {
					let candidate = base + steps.secondary * (Double(offset) * direction)
					if isFree(candidate) {
						return candidate
					}
				}
			}
		}

		return anchor + steps.primary * Double(2 * limit + 1)
	}
}
