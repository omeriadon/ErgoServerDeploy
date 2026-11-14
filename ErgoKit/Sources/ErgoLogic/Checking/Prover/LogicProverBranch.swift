//
//  LogicProverBranch.swift
//  Ergo
//
//  Created by Adon Omeri on 8/11/2026.
//

import Foundation

/// One attempt at building a situation. Copied whenever it has to try alternatives.
struct Branch {
	struct Item: Hashable {
		let node: Node
		let world: Int
	}

	struct Key: Hashable {
		let fact: Fact
		let world: Int
	}

	var agenda: [(Node, Int)] = []
	var choices: [(Node, Node, Int)] = []
	var witnesses: [(Int, Node, Int)] = []
	var names: [Int] = []

	var nextName: Int
	var seen: Set<Item> = []
	var universals: [(Int, Node, Int)] = []
	var necessities: [Node] = []
	var possibilities: Set<Node> = []
	var worldCount = 1
	var facts: [Key: Bool] = [:]
	var parents: [Int: Int] = [:]
	var differences: [(Int, Int)] = []

	/// Roughly what it costs to copy and carry on with
	var size: Int {
		seen.count
	}

	var distinctThings: [Int] {
		var found: Set<Int> = []
		return names.filter { found.insert(root(of: $0)).inserted }
	}

	mutating func makeName() -> Int {
		nextName += 1
		return nextName
	}

	/// A new thing has to meet every ∀ already made
	mutating func addThing() -> Int {
		let name = makeName()
		names.append(name)
		for (letter, body, world) in universals {
			add(body.replacing(letter, with: name), world: world)
		}
		return name
	}

	mutating func add(_ node: Node, world: Int) {
		if seen.insert(Item(node: node, world: world)).inserted {
			agenda.append((node, world))
		}
	}

	/// False when it contradicts what's already there
	mutating func apply(_ node: Node, world: Int) -> Bool {
		switch node {
			case .top:
				return true
			case .bottom:
				return false
			case let .fact(fact, value):
				return record(fact, value, world: world)
			case let .same(left, right, value):
				return record(left, right, same: value)
			case let .and(left, right):
				add(left, world: world)
				add(right, world: world)
				return true
			case let .or(left, right):
				choices.append((left, right, world))
				return true
			case let .always(value):
				necessities.append(value)
				for other in 0 ..< worldCount {
					add(value, world: other)
				}
				return true
			case let .sometimes(value):
				// In S5 it doesn't matter which world asked, so one witness is enough for everyone
				if possibilities.insert(value).inserted {
					let new = worldCount
					worldCount += 1
					for necessity in necessities {
						add(necessity, world: new)
					}
					add(value, world: new)
				}
				return true
			case let .all(letter, body):
				universals.append((letter, body, world))
				for name in names {
					add(body.replacing(letter, with: name), world: world)
				}
				return true
			case let .some(letter, body):
				witnesses.append((letter, body, world))
				return true
		}
	}

	/// True or false when what's known already decides it, nil when it doesn't
	func truth(of node: Node, world: Int) -> Bool? {
		switch node {
			case .top:
				return true
			case .bottom:
				return false
			case let .fact(fact, value):
				return facts[Key(fact: canonical(fact), world: world)].map { $0 == value }
			case let .same(left, right, value):
				guard case let .name(left) = left, case let .name(right) = right else { return nil }
				let (first, second) = (root(of: left), root(of: right))
				if first == second {
					return value
				}
				let isDifferent = differences.contains { pair in
					let pair = (root(of: pair.0), root(of: pair.1))
					return pair == (first, second) || pair == (second, first)
				}
				return isDifferent ? !value : nil
			case let .and(left, right):
				let (left, right) = (truth(of: left, world: world), truth(of: right, world: world))
				if left == false || right == false {
					return false
				}
				return left == true && right == true ? true : nil
			case let .or(left, right):
				let (left, right) = (truth(of: left, world: world), truth(of: right, world: world))
				if left == true || right == true {
					return true
				}
				return left == false && right == false ? false : nil
			case .always, .sometimes, .all, .some:
				return nil
		}
	}

	/// Drops the choices that are already met, and takes the only side left of those with one ruled out.
	/// False when both sides of one are ruled out.
	mutating func settleChoices() -> Bool {
		var open: [(Node, Node, Int)] = []
		for choice in choices {
			let (left, right, world) = choice
			switch (truth(of: left, world: world), truth(of: right, world: world)) {
				case (true, _), (_, true):
					break
				case (false, false):
					return false
				case (false, nil):
					add(right, world: world)
				case (nil, false):
					add(left, world: world)
				case (nil, nil):
					open.append(choice)
			}
		}
		choices = open
		return true
	}

	func root(of name: Int) -> Int {
		var current = name
		while let parent = parents[current] {
			current = parent
		}
		return current
	}

	func canonical(_ fact: Fact) -> Fact {
		Fact(kind: fact.kind, things: fact.things.map { thing in
			if case let .name(name) = thing {
				return .name(root(of: name))
			}
			return thing
		})
	}

	private mutating func record(_ fact: Fact, _ value: Bool, world: Int) -> Bool {
		let key = Key(fact: canonical(fact), world: world)
		if let known = facts[key] {
			return known == value
		}
		facts[key] = value
		return true
	}

	private mutating func record(_ left: Thing, _ right: Thing, same: Bool) -> Bool {
		guard case let .name(left) = left, case let .name(right) = right else { return true }
		let (first, second) = (root(of: left), root(of: right))

		guard same else {
			differences.append((first, second))
			return first != second
		}
		guard first != second else { return true }

		parents[first] = second
		guard !differences.contains(where: { root(of: $0.0) == root(of: $0.1) }) else { return false }

		// Facts about the old name are now facts about the new one, which might contradict what's known
		let old = facts
		facts = [:]
		for (key, value) in old {
			let moved = Key(fact: canonical(key.fact), world: key.world)
			if let known = facts[moved], known != value {
				return false
			}
			facts[moved] = value
		}
		return true
	}
}
