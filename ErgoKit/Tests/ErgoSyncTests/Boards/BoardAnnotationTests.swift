//
//  BoardAnnotationTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 8/11/2026.
//

import ErgoSync
import Foundation
import Testing

/// The records the server writes for a board analysis
struct BoardAnnotationTests {
	static let boardID = UUID(uuidString: "6F1C2E9A-3B4D-4E5F-8A9B-0C1D2E3F4A5B")!
	static let premise = UUID(uuidString: "AAAAAAAA-2222-4333-8444-555555555555")!
	static let conclusion = UUID(uuidString: "BBBBBBBB-2222-4333-8444-555555555555")!
	static let stamp = SyncStamp(time: 1_793_836_800_000, counter: 0, device: "server")

	static let annotation = BoardAnnotation(
		id: UUID(uuidString: "CCCCCCCC-2222-4333-8444-555555555555")!,
		board: boardID,
		run: UUID(uuidString: "DDDDDDDD-2222-4333-8444-555555555555")!,
		target: .link(UUID(uuidString: "EEEEEEEE-2222-4333-8444-555555555555")!),
		citation: LibraryCitation(category: "fallacies", id: "straw-man", name: "Straw man"),
		quote: nil,
		markdown: "A *weak* step, see [Straw man](ergo://intent).",
		assessment: .arrow(.weak),
		basis: [premise: "It rained.", conclusion: "The ground is wet."]
	)

	static let status = BoardAnalysisStatus(
		board: boardID,
		run: annotation.run,
		state: .finished,
		started: Date(timeIntervalSince1970: 1_793_836_800),
		finished: Date(timeIntervalSince1970: 1_793_836_900),
		error: nil,
		discussion: "Overall, fine."
	)

	static func record(_ kind: SyncKind, _ id: String, _ fields: [String: JSONValue]) -> SyncRecord {
		SyncRecord(kind: kind, id: id, fields: fields.mapValues { SyncField(value: $0, stamp: stamp) })
	}

	@Test func anAnnotationRoundTripsThroughARecord() {
		let record = Self.record(.annotation, Self.annotation.recordID, Self.annotation.fields)
		#expect(BoardAnnotation(record) == Self.annotation)
		#expect(Set(Self.annotation.fields.keys).isSubset(of: SyncKind.annotation.fieldNames))
		#expect(Self.annotation.fields[SyncFieldName.board] == .string(Self.boardID.uuidString))
	}

	@Test func everyShapeOfAnnotationRoundTrips() {
		let citation = Self.annotation.citation
		let all = [
			BoardAnnotation(id: UUID(), board: Self.boardID, run: UUID(), target: .statement(Self.premise), citation: citation, quote: "it rained", markdown: "m", assessment: nil, basis: [:]),
			BoardAnnotation(id: UUID(), board: Self.boardID, run: UUID(), target: .source(Self.premise), citation: citation, quote: "x y", markdown: "m", assessment: nil, basis: [Self.premise: "Title"]),
			BoardAnnotation(id: UUID(), board: Self.boardID, run: UUID(), target: .statement(Self.conclusion), citation: citation, quote: nil, markdown: "m", assessment: .conclusion(.partlySupported), basis: Self.annotation.basis),
		] + BoardArrowStrength.allCases.map {
			BoardAnnotation(id: UUID(), board: Self.boardID, run: UUID(), target: .link(UUID()), citation: citation, quote: nil, markdown: "m", assessment: .arrow($0), basis: [:])
		}
		for annotation in all {
			#expect(BoardAnnotation(Self.record(.annotation, annotation.recordID, annotation.fields)) == annotation)
		}
	}

	/// A dictionary with `UUID` keys would encode as a flat array, which other readers couldn't use
	@Test func theBasisIsAnObjectKeyedByID() {
		guard case let .object(content)? = Self.annotation.fields[SyncFieldName.content], case let .object(basis)? = content["basis"] else {
			Issue.record("Expected an object")
			return
		}
		#expect(basis[Self.premise.uuidString] == "It rained.")
	}

	@Test func aStatusRoundTripsThroughARecord() {
		let record = Self.record(.analysis, Self.status.recordID, Self.status.fields)
		#expect(Self.status.recordID == Self.boardID.uuidString)
		#expect(BoardAnalysisStatus(record) == Self.status)
		#expect(Set(Self.status.fields.keys).isSubset(of: SyncKind.analysis.fieldNames))

		let failed = BoardAnalysisStatus(board: Self.boardID, run: UUID(), state: .failed, started: Self.status.started, error: "Expected a reply in time, found none")
		#expect(BoardAnalysisStatus(Self.record(.analysis, failed.recordID, failed.fields)) == failed)
	}

	@Test func theyAreNilForWhatTheyCantRead() {
		var wrongKind = Self.record(.annotation, Self.annotation.recordID, Self.annotation.fields)
		wrongKind.kind = .statement
		#expect(BoardAnnotation(wrongKind) == nil)

		var tombstone = Self.record(.annotation, Self.annotation.recordID, Self.annotation.fields)
		tombstone.fields[SyncFieldName.deleted] = SyncField(value: true, stamp: SyncStamp(time: Self.stamp.time + 1, counter: 0, device: "server"))
		#expect(BoardAnnotation(tombstone) == nil)

		let garbage = Self.record(.annotation, Self.annotation.recordID, [SyncFieldName.board: .string(Self.boardID.uuidString), SyncFieldName.content: "nonsense"])
		#expect(BoardAnnotation(garbage) == nil)
		#expect(BoardAnnotation(Self.record(.annotation, Self.annotation.recordID, [:])) == nil)

		#expect(BoardAnalysisStatus(Self.record(.annotation, Self.status.recordID, Self.status.fields)) == nil)
		#expect(BoardAnnotation(Self.record(.annotation, "not the annotation's id", Self.annotation.fields)) == nil)
	}

	@Test func theKindsAreServerOwned() {
		for kind in [SyncKind.annotation, .analysis] {
			#expect(kind.isServerOwned)
			#expect(!SyncKind.known.contains(kind))
			#expect(kind.fieldNames == ["board", "content", "deleted"])
			#expect(kind.isValid(id: Self.boardID.uuidString))
			#expect(!kind.isValid(id: Self.boardID.uuidString.lowercased()))
		}
		#expect(SyncKind.annotation.rawValue == "annotation")
		#expect(SyncKind.analysis.rawValue == "analysis")
	}

	@Test func theyAreIgnoredWhenTheirBoardIsGoneOrDeleted() {
		var server = FakeSyncServer()
		var device = FakeDevice("A")
		device.syncUntilDone(with: &server)
		let annotation = Self.record(.annotation, Self.annotation.recordID, Self.annotation.fields)
		let status = Self.record(.analysis, Self.status.recordID, Self.status.fields)
		#expect(annotation.owningBoard == Self.boardID.uuidString)
		#expect(device.replica.isIgnored(annotation))
		#expect(device.replica.isIgnored(status))

		device.edit(.board, Self.boardID.uuidString, ["created": 1], server)
		#expect(!device.replica.isIgnored(annotation))
		#expect(!device.replica.isIgnored(status))

		device.edit(.board, Self.boardID.uuidString, ["deleted": true], server)
		#expect(device.replica.isIgnored(annotation))
		#expect(device.replica.isIgnored(status))
	}

	@Test func aReplicaNeverPushesThem() {
		var server = FakeSyncServer()
		var device = FakeDevice("A")
		device.syncUntilDone(with: &server)
		device.edit(.annotation, Self.annotation.recordID, Self.annotation.fields, server)
		device.edit(.analysis, Self.status.recordID, Self.status.fields, server)
		#expect(device.replica.makeRequest().changes.filter(\.kind.isServerOwned).isEmpty)
	}
}
