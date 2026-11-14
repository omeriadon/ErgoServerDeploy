//
//  JSONSchemaTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoTranslation
import Foundation
import Testing

/// Every stage's schema has to be strict all the way down, or Claude and Codex turn it away
struct JSONSchemaTests {
	static let schemas: [(name: String, schema: JSONSchema)] = [
		(GateStage.name, GateStage.outputSchema),
		(BreakdownStage.name, BreakdownStage.outputSchema),
		(FormalizeStage.name, FormalizeStage.outputSchema),
		(VerifyStage.name, VerifyStage.outputSchema),
	]

	/// A real output from each stage, encoded the way a backend would send it
	static let samples: [String: Data] = {
		let encoder = JSONEncoder()
		return [
			GateStage.name: try! encoder.encode(GateStage.Output(kind: .argument, reason: "")),
			BreakdownStage.name: try! encoder.encode(BreakdownStage.Output(
				premises: ["If it rains, the ground gets wet"],
				conclusion: "the ground is wet",
				claims: [.init(meaning: "It rains", descriptor: "it rains")]
			)),
			FormalizeStage.name: try! encoder.encode(FormalizeStage.Output(premises: ["X → Y"], conclusion: "Y")),
			VerifyStage.name: try! encoder.encode(VerifyStage.Output(matches: false, differences: ["Reading says rains"])),
		]
	}()

	@Test(arguments: schemas.map(\.name))
	func strictAllTheWayDown(_ stage: String) throws {
		let schema = try #require(Self.schemas.first { $0.name == stage }?.schema)
		let json = try JSONSerialization.jsonObject(with: Data(schema.encoded().utf8))
		try checkStrict(json, path: stage)
	}

	@Test(arguments: schemas.map(\.name))
	func samplesMatchThePropertyNames(_ stage: String) throws {
		let schema = try #require(Self.schemas.first { $0.name == stage }?.schema)
		let sample = try #require(Self.samples[stage])
		let json = try JSONSerialization.jsonObject(with: Data(schema.encoded().utf8))
		try checkShape(JSONSerialization.jsonObject(with: sample), against: json, path: stage)
	}

	/// Stripped of descriptions, the gate's schema is exactly what was sent to the real `claude --json-schema`
	@Test func matchesTheCapturedFixture() {
		let gate = JSONSchema.object([
			.init("kind", .string(enum: ["argument", "statements", "neither"])),
			.init("reason", .string()),
		])
		#expect(gate.encoded() == #"{"type":"object","properties":{"kind":{"type":"string","enum":["argument","statements","neither"]},"reason":{"type":"string"}},"required":["kind","reason"],"additionalProperties":false}"#)
	}

	@Test func keepsDeclarationOrderAndEscapes() {
		let schema = JSONSchema.object([
			.init("b", .integer(description: "Say \"hi\"\n")),
			.init("a", .array(.boolean(), maxItems: 2)),
		], description: "Order")
		#expect(schema.encoded() == #"{"type":"object","description":"Order","properties":{"b":{"type":"integer","description":"Say \"hi\"\n"},"a":{"type":"array","items":{"type":"boolean"},"maxItems":2}},"required":["b","a"],"additionalProperties":false}"#)
	}

	@Test func limitsCarryOver() throws {
		let json = try #require(JSONSerialization.jsonObject(with: Data(BreakdownStage.outputSchema.encoded().utf8)) as? [String: Any])
		let properties = try #require(json["properties"] as? [String: [String: Any]])
		#expect(properties["premises"]?["maxItems"] as? Int == 12)
		#expect(properties["claims"]?["maxItems"] as? Int == 6)
	}

	// MARK: - Walking

	private func checkStrict(_ json: Any, path: String) throws {
		let schema = try #require(json as? [String: Any], "\(path) isn't a schema")
		let type = try #require(schema["type"] as? String, "\(path) has no type")
		#expect(["object", "array", "string", "boolean", "integer"].contains(type))

		switch type {
			case "object":
				let properties = try #require(schema["properties"] as? [String: Any], "\(path) has no properties")
				let required = try #require(schema["required"] as? [String], "\(path) has no required")
				#expect(Set(required) == Set(properties.keys), "\(path) has optional properties")
				#expect(required.count == properties.count)
				#expect(schema["additionalProperties"] as? Bool == false, "\(path) allows additional properties")
				for (name, property) in properties {
					try checkStrict(property, path: path + "." + name)
				}
			case "array":
				try checkStrict(schema["items"] as Any, path: path + "[]")
			default:
				break
		}
	}

	private func checkShape(_ value: Any, against json: Any, path: String) throws {
		let schema = try #require(json as? [String: Any])

		switch schema["type"] as? String {
			case "object":
				let object = try #require(value as? [String: Any], "\(path) isn't an object")
				let properties = try #require(schema["properties"] as? [String: Any])
				#expect(Set(object.keys) == Set(properties.keys), "\(path) doesn't match the schema's property names")
				for (name, property) in properties {
					try checkShape(object[name] as Any, against: property, path: path + "." + name)
				}
			case "array":
				let array = try #require(value as? [Any], "\(path) isn't an array")
				for element in array {
					try checkShape(element, against: schema["items"] as Any, path: path + "[]")
				}
			case "string":
				let string = try #require(value as? String, "\(path) isn't a string")
				if let values = schema["enum"] as? [String] {
					#expect(values.contains(string))
				}
			case "boolean", "integer":
				#expect(value is NSNumber, "\(path) isn't a number")
			default:
				Issue.record("\(path) has an unknown type")
		}
	}
}
