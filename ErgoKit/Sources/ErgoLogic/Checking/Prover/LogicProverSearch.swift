//
//  LogicProverSearch.swift
//  Ergo
//
//  Created by Adon Omeri on 8/11/2026.
//

import Foundation

// MARK: - Searching

struct OutOfSteps: Error {}

struct Search {
	let firstMadeUp: Int
	let stepLimit: Int

	/// Past this many things, anything still possible would already have been found
	var maximumThings: Int?

	var steps = 0

	/// How many things this pass may use
	var thingLimit = 1

	/// A pass stopped short of adding a thing, so it failing doesn't prove anything
	var reachedLimit = false

	init(firstMadeUp: Int, stepLimit: Int) {
		self.firstMadeUp = firstMadeUp
		self.stepLimit = stepLimit
	}

	mutating func isPossible(_ formulas: [Node]) throws -> Bool {
		var measure = Measure()
		formulas.forEach { measure.add($0) }

		// New names are numbered well past the letters ∀ and ∃ made up during translation
		var branch = Branch(nextName: firstMadeUp * 2)
		for name in measure.names.sorted() {
			branch.names.append(name)
		}
		if branch.names.isEmpty {
			branch.names.append(branch.makeName())
		}

		for formula in formulas {
			branch.add(formula, world: 0)
		}

		// One thing, then two, and so on, which finds the smallest model. Going deep first can miss one forever.
		thingLimit = branch.distinctThings.count
		while true {
			reachedLimit = false
			if try isOpen(branch) {
				return true
			}
			guard reachedLimit else { return false }
			if let maximumThings, thingLimit >= maximumThings {
				return false
			}
			thingLimit += 1
		}
	}

	/// Whether this attempt can be finished without contradicting itself. Alternatives wait in a list rather than
	/// on the call stack, since a deep search would overflow it, and the stack on the main thread is small.
	private mutating func isOpen(_ start: Branch) throws -> Bool {
		var alternatives = [start]

		while var branch = alternatives.popLast() {
			attempt: while true {
				steps += 1
				guard steps < stepLimit else { throw OutOfSteps() }

				if let (node, world) = branch.agenda.popLast() {
					guard branch.apply(node, world: world) else { break attempt }
					continue
				}

				// What's already known often settles a choice, and that's far cheaper than trying both sides
				steps += branch.choices.count
				guard branch.settleChoices() else { break attempt }
				if !branch.agenda.isEmpty {
					continue
				}

				if let (left, right, world) = branch.choices.popLast() {
					steps += branch.size
					var other = branch
					other.add(right, world: world)
					// Trying the right side only matters when the left is false
					switch left {
						case .fact, .same:
							other.add(left.negated, world: world)
						default:
							break
					}
					alternatives.append(other)
					branch.add(left, world: world)
					continue
				}

				if let (letter, body, world) = branch.witnesses.popLast() {
					let things = branch.distinctThings
					steps += branch.size * (things.count + 1)

					let instances = things.map { (name: $0, known: branch.truth(of: body.replacing(letter, with: $0), world: world)) }
					if instances.contains(where: { $0.known == true }) {
						continue
					}

					// Tried last, since something that already exists might do, which keeps models small and finite
					if things.count < thingLimit {
						var other = branch
						let name = other.addThing()
						other.add(body.replacing(letter, with: name), world: world)
						alternatives.append(other)
					} else {
						reachedLimit = true
					}

					for (name, known) in instances.reversed() where known != false {
						var other = branch
						other.add(body.replacing(letter, with: name), world: world)
						alternatives.append(other)
					}
					break attempt
				}

				return true
			}
		}

		return false
	}
}
