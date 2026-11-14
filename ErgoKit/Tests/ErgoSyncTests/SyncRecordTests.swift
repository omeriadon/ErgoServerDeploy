//
//  SyncRecordTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoSync
import Foundation
import Testing

struct SyncRecordTests {
	static func stamp(_ time: Int64, _ device: String = "A", counter: Int = 0) -> SyncStamp {
		SyncStamp(time: time, counter: counter, device: device)
	}

	static func board(_ fields: [String: SyncField]) -> SyncRecord {
		SyncRecord(kind: .board, id: "6F1C2E9A-3B4D-4E5F-8A9B-0C1D2E3F4A5B", fields: fields)
	}

	// MARK: - JSONValue

	@Test func jsonValuesRoundTrip() throws {
		let json = #"[null,true,false,0,1,-2.5,"s",[],{"a":{"b":[1,"x"]}}]"#
		let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
		#expect(value == [nil, true, false, 0, 1, -2.5, "s", [], ["a": ["b": [1, "x"]]]])
		#expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) == value)
	}

	/// The server stores a lone string or bool as a field value, not only objects
	@Test func fragmentsRoundTrip() throws {
		for value: JSONValue in [nil, true, 3, "it rains"] {
			#expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) == value)
		}
	}

	@Test func codableValuesConvert() throws {
		struct Content: Codable, Equatable {
			var english: String
			var logic: [Int]
			var source: String?
		}
		let content = Content(english: "It rains.", logic: [1, 2], source: nil)
		let value = try JSONValue(content)

		#expect(value == ["english": "It rains.", "logic": [1, 2]])
		#expect(try value.decode(Content.self) == content)
		#expect(try JSONValue(content) == value)
		#expect(throws: DecodingError.self) { try JSONValue.string("x").decode(Int.self) }
	}

	@Test func byteCountIsCompactJSON() {
		#expect(JSONValue.string("abc").byteCount == 5)
		#expect(JSONValue.object(["a": true]).byteCount == 10)
	}

	// MARK: - Merging

	/// Random records over a few names, stamps and values, so ties and equal stamps with different values both happen
	static func randomRecord(_ random: inout SeededRandom) -> SyncRecord {
		let names = ["content", "deleted", "descriptor.0", "descriptor.1"]
		let values: [JSONValue] = [nil, true, false, 1, "x", "y", ["x"], ["a": 1]]
		var record = board([:])
		for name in names where Bool.random(using: &random) {
			let stamp = stamp(Int64.random(in: 0 ... 3, using: &random), ["A", "B"].randomElement(using: &random)!, counter: Int.random(in: 0 ... 1, using: &random))
			record.fields[name] = SyncField(value: values.randomElement(using: &random)!, stamp: stamp)
		}
		return record
	}

	@Test(arguments: 0 ..< 200 as Range<UInt64>)
	func mergeIsCommutativeAssociativeAndIdempotent(seed: UInt64) {
		var random = SeededRandom(seed: seed)
		let a = Self.randomRecord(&random)
		let b = Self.randomRecord(&random)
		let c = Self.randomRecord(&random)

		#expect(SyncRecord.merge(a, b) == SyncRecord.merge(b, a))
		#expect(SyncRecord.merge(SyncRecord.merge(a, b), c) == SyncRecord.merge(a, SyncRecord.merge(b, c)))
		#expect(SyncRecord.merge(a, a) == a)
		#expect(SyncRecord.merge(SyncRecord.merge(a, b), b) == SyncRecord.merge(a, b))
	}

	@Test func mergeKeepsTheNewerFieldEach() {
		let a = Self.board(["content": SyncField(value: "a", stamp: Self.stamp(2)), "descriptor.0": SyncField(value: "rain", stamp: Self.stamp(1))])
		let b = Self.board(["content": SyncField(value: "b", stamp: Self.stamp(1, "B")), "descriptor.0": SyncField(value: "snow", stamp: Self.stamp(3, "B"))])
		#expect(SyncRecord.merge(a, b).values == ["content": "a", "descriptor.0": "snow"])
		#expect(SyncRecord.merge(a, b).newestStamp == Self.stamp(3, "B"))
	}

	// MARK: - Tombstones

	@Test func aNewerDeleteDeletes() {
		let record = Self.board(["content": SyncField(value: "a", stamp: Self.stamp(1)), "deleted": SyncField(value: true, stamp: Self.stamp(2))])
		#expect(record.isDeleted)
	}

	/// One device deletes a board while another keeps typing in it: the typing brings it back
	@Test func typingAfterADeleteWins() {
		let deleted = Self.board(["content": SyncField(value: "a", stamp: Self.stamp(1)), "deleted": SyncField(value: true, stamp: Self.stamp(2))])
		let typed = Self.board(["content": SyncField(value: "ab", stamp: Self.stamp(3, "B"))])
		#expect(!SyncRecord.merge(deleted, typed).isDeleted)
		#expect(!SyncRecord.merge(typed, deleted).isDeleted)
	}

	@Test func undoingADeleteIsANewerFalse() {
		var record = Self.board(["content": SyncField(value: "a", stamp: Self.stamp(1)), "deleted": SyncField(value: true, stamp: Self.stamp(2))])
		record.merge(["deleted": SyncField(value: false, stamp: Self.stamp(3))])
		#expect(!record.isDeleted)
		#expect(!Self.board([:]).isDeleted)
		#expect(Self.board([:]).newestStamp == nil)
	}

	// MARK: - Pushes

	@Test func anEditFromWhatsStoredIsntConcurrent() {
		var stored = Self.board(["content": SyncField(value: "a", stamp: Self.stamp(1))])
		let change = SyncChange(kind: .board, id: stored.id, fields: ["content": SyncField(value: "ab", stamp: Self.stamp(2, "B"))], bases: ["content": Self.stamp(1)])
		#expect(stored.apply(change).isEmpty)
		#expect(stored.values == ["content": "ab"])

		// A retry of the same push isn't either
		#expect(stored.apply(change).isEmpty)
	}

	@Test func aNewerConcurrentEditSupersedesWhatsStored() {
		var stored = Self.board(["content": SyncField(value: "a", stamp: Self.stamp(2))])
		let change = SyncChange(kind: .board, id: stored.id, fields: ["content": SyncField(value: "b", stamp: Self.stamp(3, "B"))], bases: ["content": Self.stamp(1)])
		#expect(stored.apply(change) == [SupersededField(kind: .board, id: stored.id, field: "content", lost: SyncField(value: "a", stamp: Self.stamp(2)))])
		#expect(stored.values == ["content": "b"])
	}

	@Test func anOlderConcurrentEditIsItselfSuperseded() {
		var stored = Self.board(["content": SyncField(value: "a", stamp: Self.stamp(3))])
		let pushed = SyncField(value: "b", stamp: Self.stamp(2, "B"))
		let change = SyncChange(kind: .board, id: stored.id, fields: ["content": pushed])
		#expect(stored.apply(change) == [SupersededField(kind: .board, id: stored.id, field: "content", lost: pushed)])
		#expect(stored.values == ["content": "a"])
	}

	@Test func equalValuesArentAConflict() {
		var stored = Self.board(["content": SyncField(value: "a", stamp: Self.stamp(2))])
		let change = SyncChange(kind: .board, id: stored.id, fields: ["content": SyncField(value: "a", stamp: Self.stamp(3, "B"))])
		#expect(stored.apply(change).isEmpty)
	}

	@Test func aNewFieldIsntAConflict() {
		var stored = Self.board(["content": SyncField(value: "a", stamp: Self.stamp(2))])
		let change = SyncChange(kind: .board, id: stored.id, fields: ["descriptor.0": SyncField(value: "rain", stamp: Self.stamp(1, "B"))])
		#expect(stored.apply(change).isEmpty)
		#expect(stored.values == ["content": "a", "descriptor.0": "rain"])
	}

	// MARK: - Checks

	@Test func kindsKnowTheirFieldsAndIDs() {
		#expect(SyncKind.board.fieldNames == ["created", "name", "deleted"])
		#expect(SyncKind.scratchpad.fieldNames == ["created", "name", "content", "deleted", "descriptor.0", "descriptor.1", "descriptor.2", "descriptor.3", "descriptor.4", "descriptor.5"])
		#expect(SyncKind.bookmark.fieldNames == ["present"])
		#expect(SyncKind.setting.fieldNames == ["value"])
		#expect(SyncKind(rawValue: "folder").fieldNames.isEmpty)

		#expect(SyncKind.board.isValid(id: "6F1C2E9A-3B4D-4E5F-8A9B-0C1D2E3F4A5B"))
		#expect(!SyncKind.board.isValid(id: "6f1c2e9a-3b4d-4e5f-8a9b-0c1d2e3f4a5b"))
		#expect(SyncKind.scratchpad.isValid(id: "6F1C2E9A-3B4D-4E5F-8A9B-0C1D2E3F4A5B"))
		#expect(!SyncKind.scratchpad.isValid(id: "6f1c2e9a-3b4d-4e5f-8a9b-0c1d2e3f4a5b"))
		#expect(SyncKind.setting.isValid(id: "logicLetters"))
		#expect(!SyncKind.setting.isValid(id: "translationServer"))
		#expect(SyncKind.bookmark.isValid(id: "fallacy.ad-hominem"))
		#expect(!SyncKind.bookmark.isValid(id: ""))
		#expect(SyncedSetting.allCases.map(\.rawValue) == ["logicLetters", "ditherEnabled", "translationProvider", "hapticsEnabled", "itemOfTheDayCategories", "agentInstructions"])
	}

	/// An older app still decodes a kind added later, so one new kind can't break everyone's sync
	@Test func unknownKindsDecode() throws {
		let record = try JSONDecoder().decode(SyncRecord.self, from: Data(#"{"kind":"folder","id":"x","fields":{}}"#.utf8))
		#expect(record.kind == SyncKind(rawValue: "folder"))
		#expect(try String(decoding: JSONEncoder().encode(SyncKind.board), as: UTF8.self) == #""board""#)
	}
}
