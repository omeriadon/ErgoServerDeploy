//
//  LayeredGraph.swift
//  Ergo
//
//  Created by Adon Omeri on 8/11/2026.
//

import Foundation

/// The working behind `CanvasLayout.positions`. Statements are their place in the topological order, so every arrow
/// here points from a lower number to a higher one. Links caught in a cycle point backwards and are left out.
struct LayeredGraph {
	typealias Arrow = (premise: Int, conclusion: Int)

	static let half = CanvasLayout.columnPitch / 2

	/// How many half-column steps a row searches either way for its best spot
	static let searchReach = 12

	/// Enough for the sweeps to settle. The best one is kept, so more only costs time.
	static let sweeps = 12

	static let repairPasses = 3
	static let repairReach = 4

	/// What a layout pays, in columns squared of arrow slant, for an arrow through a box and for two arrows crossing
	static let hitCost = 1000.0
	static let crossingCost = 20.0

	let count: Int
	var arrows: [Arrow] = []
	var premises: [[Int]]
	var conclusions: [[Int]]

	init(order: [UUID], links: [(UUID, UUID)]) {
		count = order.count
		premises = Array(repeating: [], count: order.count)
		conclusions = Array(repeating: [], count: order.count)

		let number = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
		var seen: Set<Int> = []
		for (premise, conclusion) in links {
			guard let from = number[premise], let to = number[conclusion], from < to else { continue }
			if seen.insert(from * order.count + to).inserted {
				arrows.append((from, to))
				premises[to].append(from)
				conclusions[from].append(to)
			}
		}
	}

	static func snapped(_ x: Double) -> Double {
		(x / half).rounded() * half
	}

	// MARK: - Groups

	/// Each set of statements joined by links, then every statement with no links at all as one last group
	var groups: [[Int]] {
		var leader = Array(0 ..< count)
		func find(_ statement: Int) -> Int {
			var statement = statement
			while leader[statement] != statement {
				statement = leader[statement]
			}
			return statement
		}
		for arrow in arrows {
			let (a, b) = (find(arrow.premise), find(arrow.conclusion))
			leader[max(a, b)] = min(a, b)
		}

		var linked: [Int: [Int]] = [:]
		var loose: [Int] = []
		for statement in 0 ..< count {
			if premises[statement].isEmpty, conclusions[statement].isEmpty {
				loose.append(statement)
			} else {
				linked[find(statement), default: []].append(statement)
			}
		}

		let joined = linked.keys.sorted().compactMap { linked[$0] }
		return loose.isEmpty ? joined : joined + [loose]
	}

	// MARK: - Rows

	/// The group's rows, top to bottom. A layer is the longest chain of premises behind a statement, then anything with
	/// slack moves down next to what it feeds, which is how a lone premise ends up right above its conclusion instead of
	/// sending a long arrow past everything between. Moving a statement that has as many premises as conclusions changes
	/// no arrow's length overall, but lets the statements above it follow.
	func rows(of group: [Int]) -> [[Int]] {
		var layer = [Int](repeating: 0, count: count)
		for statement in group {
			layer[statement] = premises[statement].map { layer[$0] + 1 }.max() ?? 0
		}
		for statement in group.reversed() where !conclusions[statement].isEmpty && conclusions[statement].count >= premises[statement].count {
			layer[statement] = (conclusions[statement].map { layer[$0] }.min() ?? 1) - 1
		}

		let layers = Dictionary(grouping: group) { layer[$0] }
		return layers.keys.sorted().flatMap { key -> [[Int]] in
			// Statements about the same things wrap together
			let sorted = (layers[key] ?? []).sorted { (closeness($0), $0) < (closeness($1), $1) }
			return stride(from: 0, to: sorted.count, by: CanvasLayout.maximumRowLength).map { start in
				Array(sorted[start ..< min(start + CanvasLayout.maximumRowLength, sorted.count)])
			}
		}
	}

	func closeness(_ statement: Int) -> Double {
		let neighbours = conclusions[statement] + premises[statement]
		return neighbours.isEmpty ? Double(statement) : Double(neighbours.reduce(0, +)) / Double(neighbours.count)
	}

	// MARK: - Columns

	/// Where each statement in `rows` goes across, indexed by statement. Sweeps down and up the rows, with each row
	/// settling around what's linked to it on the side just placed, and keeps the sweep that scored best.
	func columns(for rows: [[Int]]) -> [Double] {
		var rowOf = [Int](repeating: -1, count: count)
		for (index, row) in rows.enumerated() {
			for statement in row {
				rowOf[statement] = index
			}
		}
		let arrows = arrows.filter { rowOf[$0.premise] >= 0 }

		var across = [Double](repeating: 0, count: count)
		var best = across
		var bestScore = Double.infinity

		for sweep in 0 ..< Self.sweeps {
			let down = sweep % 2 == 0
			for index in down ? Array(rows.indices) : rows.indices.reversed() {
				let wanted = Dictionary(uniqueKeysWithValues: rows[index].map { statement -> (Int, Double) in
					let (first, second) = down ? (premises[statement], conclusions[statement]) : (conclusions[statement], premises[statement])
					let neighbours = first.isEmpty ? second : first
					return (statement, neighbours.isEmpty ? across[statement] : neighbours.map { across[$0] }.reduce(0, +) / Double(neighbours.count))
				})
				let row = rows[index].sorted { (wanted[$0] ?? 0, $0) < (wanted[$1] ?? 0, $1) }
				let passing = arrows.filter { rowOf[$0.premise] < index && index < rowOf[$0.conclusion] }.map { Self.reach(of: $0, across: across, rowOf: rowOf, at: index) }
				let slots = Self.slots(wanted: row.map { wanted[$0] ?? 0 }, passing: passing)
				for (statement, slot) in zip(row, slots) {
					across[statement] = slot
				}
			}

			let score = Self.score(arrows: arrows, rows: rows, rowOf: rowOf, across: across)
			if score < bestScore {
				bestScore = score
				best = across
			}
		}

		return Self.cleared(best, arrows: arrows, rows: rows, rowOf: rowOf)
	}

	/// Sweeps aim for averages, which can leave a box on an arrow that skips its row. For each one left, tries moving the
	/// box or either end of the arrow a few steps along, and keeps whichever scores best.
	static func cleared(_ across: [Double], arrows: [Arrow], rows: [[Int]], rowOf: [Int]) -> [Double] {
		var across = across
		var bestScore = score(arrows: arrows, rows: rows, rowOf: rowOf, across: across)

		for _ in 0 ..< repairPasses {
			var moved = false
			for arrow in arrows where rowOf[arrow.conclusion] - rowOf[arrow.premise] > 1 {
				for row in rowOf[arrow.premise] + 1 ..< rowOf[arrow.conclusion] {
					let passing = [reach(of: arrow, across: across, rowOf: rowOf, at: row)]
					for box in rows[row] where isBlocked(across[box], by: passing) {
						for statement in [box, arrow.conclusion, arrow.premise] {
							let home = across[statement]
							var bestSlot = home
							for step in 1 ... repairReach {
								for slot in [home - Double(step) * half, home + Double(step) * half] {
									let isFree = rows[rowOf[statement]].allSatisfy { $0 == statement || abs(across[$0] - slot) >= CanvasLayout.columnPitch }
									guard isFree else { continue }
									across[statement] = slot
									let score = score(arrows: arrows, rows: rows, rowOf: rowOf, across: across)
									if score < bestScore {
										bestScore = score
										bestSlot = slot
									}
								}
							}
							across[statement] = bestSlot
							moved = moved || bestSlot != home
						}
					}
				}
			}
			if !moved {
				break
			}
		}

		return across
	}

	/// The best slots for one row's boxes, left to right. Tries the whole row at each offset, and moves a box along when
	/// it would land on an arrow passing through, or on the box before it.
	static func slots(wanted: [Double], passing: [ClosedRange<Double>]) -> [Double] {
		var best: [Double] = []
		var bestCost = Double.infinity

		for offset in -searchReach ... searchReach {
			var slots: [Double] = []
			var cost = 0.0
			for want in wanted {
				var slot = slots.last.map { max($0 + CanvasLayout.columnPitch, snapped(want)) } ?? snapped(want) + Double(offset) * half
				for _ in 0 ..< searchReach where isBlocked(slot, by: passing) {
					slot += half
				}
				if isBlocked(slot, by: passing) {
					cost += hitCost
				}
				let distance = (slot - want) / CanvasLayout.columnPitch
				cost += distance * distance
				slots.append(slot)
			}
			if cost < bestCost {
				bestCost = cost
				best = slots
			}
		}

		return best
	}

	/// Leaves room for the box and the arrow to each lean towards the other by a `jiggle`
	static func isBlocked(_ slot: Double, by passing: [ClosedRange<Double>]) -> Bool {
		let clearance = CanvasLayout.boxSize.width / 2 + 2 * CanvasLayout.jiggle
		return passing.contains { slot + clearance > $0.lowerBound && slot - clearance < $0.upperBound }
	}

	/// How far across an arrow runs over the height of a box in row `row`
	static func reach(of arrow: Arrow, across: [Double], rowOf: [Int], at row: Int) -> ClosedRange<Double> {
		let (fromRow, toRow) = (Double(rowOf[arrow.premise]), Double(rowOf[arrow.conclusion]))
		let slant = (across[arrow.conclusion] - across[arrow.premise]) / (toRow - fromRow)
		let middle = across[arrow.premise] + slant * (Double(row) - fromRow)
		let spread = abs(slant) * (CanvasLayout.boxSize.height / 2) / CanvasLayout.rowPitch
		return middle - spread ... middle + spread
	}

	/// Lower is better. Arrows through boxes, then crossings, then how far arrows slant, with big slants costing the most.
	static func score(arrows: [Arrow], rows: [[Int]], rowOf: [Int], across: [Double]) -> Double {
		var score = 0.0
		for (index, arrow) in arrows.enumerated() {
			let slant = (across[arrow.conclusion] - across[arrow.premise]) / CanvasLayout.columnPitch
			score += slant * slant

			for row in rowOf[arrow.premise] + 1 ..< max(rowOf[arrow.conclusion], rowOf[arrow.premise] + 1) {
				let passing = [reach(of: arrow, across: across, rowOf: rowOf, at: row)]
				score += hitCost * Double(rows[row].count { isBlocked(across[$0], by: passing) })
			}

			for other in arrows[(index + 1)...] where crosses(arrow, other, rowOf: rowOf, across: across) {
				score += crossingCost
			}
		}
		return score
	}

	/// Whether two arrows cross on the way between their boxes. Arrows sharing a box don't.
	static func crosses(_ a: Arrow, _ b: Arrow, rowOf: [Int], across: [Double]) -> Bool {
		guard a.premise != b.premise, a.premise != b.conclusion, a.conclusion != b.premise, a.conclusion != b.conclusion, rowOf[a.premise] < rowOf[b.conclusion], rowOf[b.premise] < rowOf[a.conclusion] else { return false }

		func side(_ arrow: Arrow, of statement: Int) -> Double {
			let (dx, dy) = (across[arrow.conclusion] - across[arrow.premise], Double(rowOf[arrow.conclusion] - rowOf[arrow.premise]))
			return dx * Double(rowOf[statement] - rowOf[arrow.premise]) - dy * (across[statement] - across[arrow.premise])
		}
		return side(a, of: b.premise) * side(a, of: b.conclusion) < 0 && side(b, of: a.premise) * side(b, of: a.conclusion) < 0
	}
}
