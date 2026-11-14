//
//  SyncField.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import Foundation

/// One named value in a record, with the stamp of the write that set it
public struct SyncField: Codable, Sendable, Hashable {
	public var value: JSONValue
	public var stamp: SyncStamp

	public init(value: JSONValue, stamp: SyncStamp) {
		self.value = value
		self.stamp = stamp
	}

	/// The field a merge keeps: the newer stamp, or on an exact tie (which honest devices never make) the greater value
	public static func newer(_ a: SyncField, _ b: SyncField) -> SyncField {
		if a.stamp != b.stamp {
			return a.stamp > b.stamp ? a : b
		}
		return JSONValue.precedes(a.value, b.value) ? b : a
	}
}

// MARK: - Names

/// The field names records use, shared so the app and the server's checks can't drift
public enum SyncFieldName {
	/// board, statement, link, scratchpad: a tombstone. A record is deleted while this is `true` and newer than every other field.
	public static let deleted = "deleted"

	/// board, scratchpad: when it was made
	public static let created = "created"

	/// board, scratchpad: the name its owner gave it, or an empty string to be titled from what's written
	public static let name = "name"

	/// source (a statement's): the id of the source it was broken down from, or null. That's what makes a region on the canvas,
	/// and it's on the statement so one device moving a card out never clashes with another adding one.
	public static let source = "source"

	/// annotation: a `BoardAnnotation`. analysis: a `BoardAnalysisStatus`. statement: the English. source: `{ type, text, url, title }`. scratchpad: `{ english, logic, source, translation }` together, since English and logic
	/// follow each other. Opaque to the server. A board record refuses it.
	public static let content = "content"

	/// statement, link, source, annotation, analysis: the owning board's id (uppercase UUID string). Statements and links whose board is deleted
	/// or missing are ignored on read and pruned by the server.
	public static let board = "board"

	/// statement: `{ x, y }` in canvas coordinates, written when a drag ends
	public static let position = "position"

	/// link: the id of the statement that is the premise, the arrow's tail
	public static let premise = "premise"

	/// link: the id of the statement that is the conclusion, the arrow's head
	public static let conclusion = "conclusion"

	/// bookmark: whether it's bookmarked
	public static let present = "present"

	/// setting: the setting's value
	public static let value = "value"

	/// share: what this account can do on the board, a `BoardRole` raw value
	public static let role = "role"

	/// share: this account's member id (uppercase UUID string)
	public static let member = "member"

	/// share: everyone on the board, owner included, as `[BoardMember]`
	public static let members = "members"

	/// scratchpad: one per letter slot, so naming different letters on two devices keeps both
	public static func descriptor(_ slot: Int) -> String {
		"descriptor.\(slot)"
	}

	/// How many letter slots a scratchpad has, `LogicLetters.defaults.count`
	public static let descriptorSlots = 6
}
