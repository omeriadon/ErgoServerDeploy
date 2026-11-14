//
//  LogicProverFormulas.swift
//  Ergo
//
//  Created by Adon Omeri on 8/11/2026.
//

import Foundation

// MARK: - Formulas

/// What the search works on, with every negation pushed down onto a fact
indirect enum Node: Hashable {
	case top
	case bottom
	case fact(Fact, Bool)
	case same(Thing, Thing, Bool)
	case and(Node, Node)
	case or(Node, Node)
	case always(Node)
	case sometimes(Node)
	case all(Int, Node)
	case some(Int, Node)
}

enum Thing: Hashable {
	case bound(Int)
	case name(Int)
}

struct Fact: Hashable {
	enum Kind: Hashable {
		case statement(Int)
		case predicate(Int)
		case set(Int)
	}

	let kind: Kind
	var things: [Thing]
}

func both(_ left: Node, _ right: Node) -> Node {
	switch (left, right) {
		case (.bottom, _), (_, .bottom): .bottom
		case let (.top, other), let (other, .top): other
		default: .and(left, right)
	}
}

func either(_ left: Node, _ right: Node) -> Node {
	switch (left, right) {
		case (.top, _), (_, .top): .top
		case let (.bottom, other), let (other, .bottom): other
		default: .or(left, right)
	}
}

extension Node {
	var negated: Node {
		switch self {
			case .top: .bottom
			case .bottom: .top
			case let .fact(fact, value): .fact(fact, !value)
			case let .same(left, right, value): .same(left, right, !value)
			case let .and(left, right): either(left.negated, right.negated)
			case let .or(left, right): both(left.negated, right.negated)
			case let .always(value): .sometimes(value.negated)
			case let .sometimes(value): .always(value.negated)
			case let .all(letter, body): .some(letter, body.negated)
			case let .some(letter, body): .all(letter, body.negated)
		}
	}

	func mentions(_ letter: Int) -> Bool {
		switch self {
			case .top, .bottom:
				false
			case let .fact(fact, _):
				fact.things.contains(.bound(letter))
			case let .same(left, right, _):
				left == .bound(letter) || right == .bound(letter)
			case let .and(left, right), let .or(left, right):
				left.mentions(letter) || right.mentions(letter)
			case let .always(value), let .sometimes(value):
				value.mentions(letter)
			case let .all(other, body), let .some(other, body):
				other != letter && body.mentions(letter)
		}
	}

	func replacing(_ letter: Int, with name: Int) -> Node {
		func swap(_ thing: Thing) -> Thing {
			thing == .bound(letter) ? .name(name) : thing
		}

		switch self {
			case .top, .bottom:
				return self
			case let .fact(fact, value):
				return .fact(Fact(kind: fact.kind, things: fact.things.map(swap)), value)
			case let .same(left, right, value):
				return .same(swap(left), swap(right), value)
			case let .and(left, right):
				return .and(left.replacing(letter, with: name), right.replacing(letter, with: name))
			case let .or(left, right):
				return .or(left.replacing(letter, with: name), right.replacing(letter, with: name))
			case let .always(value):
				return .always(value.replacing(letter, with: name))
			case let .sometimes(value):
				return .sometimes(value.replacing(letter, with: name))
			case let .all(other, body):
				return other == letter ? self : .all(other, body.replacing(letter, with: name))
			case let .some(other, body):
				return other == letter ? self : .some(other, body.replacing(letter, with: name))
		}
	}

	/// Pushes quantifiers as far in as they go, since separate small ones need far less searching than nested ones
	var miniscoped: Node {
		switch self {
			case .top, .bottom, .fact, .same:
				return self
			case let .and(left, right):
				return both(left.miniscoped, right.miniscoped)
			case let .or(left, right):
				return either(left.miniscoped, right.miniscoped)
			case let .always(value):
				return .always(value.miniscoped)
			case let .sometimes(value):
				return .sometimes(value.miniscoped)
			case let .all(letter, body):
				let body = body.miniscoped
				guard body.mentions(letter) else { return body }
				switch body {
					case let .and(left, right):
						return both(Node.all(letter, left).miniscoped, Node.all(letter, right).miniscoped)
					case let .or(left, right) where !right.mentions(letter):
						return either(Node.all(letter, left).miniscoped, right)
					case let .or(left, right) where !left.mentions(letter):
						return either(left, Node.all(letter, right).miniscoped)
					default:
						return .all(letter, body)
				}
			case let .some(letter, body):
				let body = body.miniscoped
				guard body.mentions(letter) else { return body }
				switch body {
					case let .or(left, right):
						return either(Node.some(letter, left).miniscoped, Node.some(letter, right).miniscoped)
					case let .and(left, right) where !right.mentions(letter):
						return both(Node.some(letter, left).miniscoped, right)
					case let .and(left, right) where !left.mentions(letter):
						return both(left, Node.some(letter, right).miniscoped)
					default:
						return .some(letter, body)
				}
		}
	}
}
