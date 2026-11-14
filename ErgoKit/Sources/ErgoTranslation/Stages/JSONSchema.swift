//
//  JSONSchema.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import Foundation

/// Just enough JSON Schema for the stages' outputs. Every object is strict, every property required and nothing extra allowed,
/// since that's what both Claude's `--json-schema` and Codex's `--output-schema` accept.
public indirect enum JSONSchema: Hashable, Sendable {
	/// Properties stay in declaration order
	case object([Property], description: String? = nil)
	case array(JSONSchema, maxItems: Int? = nil, description: String? = nil)
	case string(enum: [String]? = nil, description: String? = nil)
	case boolean(description: String? = nil)
	case integer(description: String? = nil)

	public struct Property: Hashable, Sendable {
		public let name: String
		public let schema: JSONSchema

		public init(_ name: String, _ schema: JSONSchema) {
			self.name = name
			self.schema = schema
		}
	}

	/// Compact, for passing on a command line or writing to a file
	public func encoded() -> String {
		switch self {
			case let .object(properties, description):
				Self.object([
					("type", Self.quoted("object")),
					description.map { ("description", Self.quoted($0)) },
					("properties", Self.object(properties.map { ($0.name, $0.schema.encoded()) })),
					("required", Self.array(properties.map { Self.quoted($0.name) })),
					("additionalProperties", "false"),
				])

			case let .array(items, maxItems, description):
				Self.object([
					("type", Self.quoted("array")),
					description.map { ("description", Self.quoted($0)) },
					("items", items.encoded()),
					maxItems.map { ("maxItems", String($0)) },
				])

			case let .string(values, description):
				Self.object([
					("type", Self.quoted("string")),
					description.map { ("description", Self.quoted($0)) },
					values.map { ("enum", Self.array($0.map(Self.quoted))) },
				])

			case let .boolean(description):
				Self.object([("type", Self.quoted("boolean")), description.map { ("description", Self.quoted($0)) }])

			case let .integer(description):
				Self.object([("type", Self.quoted("integer")), description.map { ("description", Self.quoted($0)) }])
		}
	}

	// MARK: - Writing JSON

	/// Hand written so the key order is the same everywhere, which a JSONEncoder doesn't promise
	private static func object(_ members: [(String, String)?]) -> String {
		"{" + members.compactMap(\.self).map { quoted($0.0) + ":" + $0.1 }.joined(separator: ",") + "}"
	}

	private static func array(_ elements: [String]) -> String {
		"[" + elements.joined(separator: ",") + "]"
	}

	private static func quoted(_ text: String) -> String {
		var quoted = "\""
		for scalar in text.unicodeScalars {
			switch scalar {
				case "\"": quoted += "\\\""
				case "\\": quoted += "\\\\"
				case "\n": quoted += "\\n"
				case "\r": quoted += "\\r"
				case "\t": quoted += "\\t"
				case _ where scalar.value < 0x20:
					quoted += "\\u" + String(repeating: "0", count: 4 - String(scalar.value, radix: 16).count) + String(scalar.value, radix: 16)
				default: quoted.unicodeScalars.append(scalar)
			}
		}
		return quoted + "\""
	}
}
