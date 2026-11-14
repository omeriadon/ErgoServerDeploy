//
//  JSONValue.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import Foundation

/// Any JSON, so the server can store and merge field values without knowing what a board is.
///
/// Numbers are `Double`, like JSON itself: integers past 2^53 lose precision, so don't put ids or hashes in a number.
public enum JSONValue: Sendable, Hashable {
	case null
	case bool(Bool)
	case number(Double)
	case string(String)
	case array([JSONValue])
	case object([String: JSONValue])
}

// MARK: - Codable values

public extension JSONValue {
	/// `value` as JSON. Use the same `encoder` every time, or equal values can come out different and look like edits.
	init(_ value: some Encodable, encoder: JSONEncoder = JSONEncoder()) throws {
		self = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
	}

	func decode<Value: Decodable>(_: Value.Type = Value.self, decoder: JSONDecoder = JSONDecoder()) throws -> Value {
		try decoder.decode(Value.self, from: JSONEncoder().encode(self))
	}
}

// MARK: - Coding

extension JSONValue: Codable {
	public init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		if container.decodeNil() {
			self = .null
		} else if let value = try? container.decode(Bool.self) {
			self = .bool(value)
		} else if let value = try? container.decode(Double.self) {
			self = .number(value)
		} else if let value = try? container.decode(String.self) {
			self = .string(value)
		} else if let value = try? container.decode([JSONValue].self) {
			self = .array(value)
		} else if let value = try? container.decode([String: JSONValue].self) {
			self = .object(value)
		} else {
			throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a JSON value")
		}
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		switch self {
			case .null:
				try container.encodeNil()
			case let .bool(value):
				try container.encode(value)
			case let .number(value):
				try container.encode(value)
			case let .string(value):
				try container.encode(value)
			case let .array(value):
				try container.encode(value)
			case let .object(value):
				try container.encode(value)
		}
	}
}

// MARK: - Order

extension JSONValue {
	/// A total order, only used to break a tie between two fields with the same stamp, so merging stays commutative
	/// even for values no honest device would send
	static func precedes(_ a: JSONValue, _ b: JSONValue) -> Bool {
		switch (a, b) {
			case (.null, .null):
				false
			case let (.bool(a), .bool(b)):
				!a && b
			case let (.number(a), .number(b)):
				a < b
			case let (.string(a), .string(b)):
				a < b
			case let (.array(a), .array(b)):
				a.lexicographicallyPrecedes(b, by: precedes)
			case let (.object(a), .object(b)):
				a.sorted { $0.key < $1.key }.lexicographicallyPrecedes(b.sorted { $0.key < $1.key }) { a, b in
					a.key != b.key ? a.key < b.key : precedes(a.value, b.value)
				}
			default:
				a.rank < b.rank
		}
	}

	private var rank: Int {
		switch self {
			case .null:
				0
			case .bool:
				1
			case .number:
				2
			case .string:
				3
			case .array:
				4
			case .object:
				5
		}
	}
}

// MARK: - Literals

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
	ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
	public init(nilLiteral _: ()) {
		self = .null
	}

	public init(booleanLiteral value: Bool) {
		self = .bool(value)
	}

	public init(integerLiteral value: Int) {
		self = .number(Double(value))
	}

	public init(floatLiteral value: Double) {
		self = .number(value)
	}

	public init(stringLiteral value: String) {
		self = .string(value)
	}

	public init(arrayLiteral elements: JSONValue...) {
		self = .array(elements)
	}

	public init(dictionaryLiteral elements: (String, JSONValue)...) {
		self = .object(Dictionary(elements) { _, last in last })
	}
}
