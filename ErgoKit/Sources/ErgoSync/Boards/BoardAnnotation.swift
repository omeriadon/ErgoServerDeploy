//
//  BoardAnnotation.swift
//  ErgoKit
//
//  Created by Adon Omeri on 8/11/2026.
//

import Foundation

/// Something on a board a report is about
public enum BoardAnalysisTarget: Codable, Sendable, Hashable {
	case statement(UUID)
	case link(UUID)
	case source(UUID)

	public var id: UUID {
		switch self {
			case let .statement(id), let .link(id), let .source(id):
				id
		}
	}

	private enum Key: String, CodingKey {
		case kind, id
	}

	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: Key.self)
		let id = try container.decode(UUID.self, forKey: .id)
		switch try container.decode(String.self, forKey: .kind) {
			case "statement":
				self = .statement(id)
			case "link":
				self = .link(id)
			case "source":
				self = .source(id)
			case let kind:
				throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Expected statement, link or source, found '\(kind)'")
		}
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: Key.self)
		switch self {
			case .statement:
				try container.encode("statement", forKey: .kind)
			case .link:
				try container.encode("link", forKey: .kind)
			case .source:
				try container.encode("source", forKey: .kind)
		}
		try container.encode(id, forKey: .id)
	}
}

/// The library entry a report cites. The server has read it this run, so it exists.
public struct LibraryCitation: Codable, Sendable, Hashable {
	public let category: String
	public let id: String
	public let name: String

	public init(category: String, id: String, name: String) {
		self.category = category
		self.id = id
		self.name = name
	}
}

/// How far an arrow's premise supports its conclusion. A judgement of the inference, never of the premise's truth.
public enum BoardArrowStrength: String, Codable, Sendable, CaseIterable {
	case conclusive, strong, weak, none
}

public enum BoardConclusionSupport: String, Codable, Sendable, CaseIterable {
	case wellSupported, partlySupported, unsupported
}

public struct BoardAnnotation: Codable, Sendable, Hashable, Identifiable {
	public enum Assessment: Codable, Sendable, Hashable {
		case arrow(BoardArrowStrength)
		case conclusion(BoardConclusionSupport)

		private enum Key: String, CodingKey {
			case arrow, conclusion
		}

		public init(from decoder: any Decoder) throws {
			let container = try decoder.container(keyedBy: Key.self)
			if let strength = try container.decodeIfPresent(BoardArrowStrength.self, forKey: .arrow) {
				self = .arrow(strength)
			} else {
				self = try .conclusion(container.decode(BoardConclusionSupport.self, forKey: .conclusion))
			}
		}

		public func encode(to encoder: any Encoder) throws {
			var container = encoder.container(keyedBy: Key.self)
			switch self {
				case let .arrow(strength):
					try container.encode(strength, forKey: .arrow)
				case let .conclusion(support):
					try container.encode(support, forKey: .conclusion)
			}
		}
	}

	public let id: UUID
	public let board: UUID
	public let run: UUID
	public let target: BoardAnalysisTarget
	public let citation: LibraryCitation

	/// Nil only on assessments
	public let quote: String?
	public let markdown: String
	public let assessment: Assessment?

	/// The strongest objection to it, as one claim, which can be added to the board as a card
	public let objection: String?

	/// One of the few findings that matter most on this board
	public let isKey: Bool

	/// Statement id -> English, for an assessment: what it was judged on, so an edit can make it stale.
	/// On a source's annotation, the source's id -> its title, which is how a link source is known to be unchanged.
	public let basis: [UUID: String]

	public init(
		id: UUID,
		board: UUID,
		run: UUID,
		target: BoardAnalysisTarget,
		citation: LibraryCitation,
		quote: String?,
		markdown: String,
		assessment: Assessment?,
		objection: String? = nil,
		isKey: Bool = false,
		basis: [UUID: String]
	) {
		self.id = id
		self.board = board
		self.run = run
		self.target = target
		self.citation = citation
		self.quote = quote
		self.markdown = markdown
		self.assessment = assessment
		self.objection = objection
		self.isKey = isKey
		self.basis = basis
	}

	private enum Key: String, CodingKey {
		case id, board, run, target, citation, quote, markdown, assessment, objection, isKey, basis
	}

	/// The basis is an object keyed by uppercase id, since a dictionary with `UUID` keys would encode as a flat array
	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: Key.self)
		let basis = try container.decode([String: String].self, forKey: .basis)
		var decoded: [UUID: String] = [:]
		for (key, english) in basis {
			guard let id = UUID(uuidString: key) else {
				throw DecodingError.dataCorruptedError(forKey: .basis, in: container, debugDescription: "Expected an id, found '\(key)'")
			}
			decoded[id] = english
		}
		try self.init(
			id: container.decode(UUID.self, forKey: .id),
			board: container.decode(UUID.self, forKey: .board),
			run: container.decode(UUID.self, forKey: .run),
			target: container.decode(BoardAnalysisTarget.self, forKey: .target),
			citation: container.decode(LibraryCitation.self, forKey: .citation),
			quote: container.decodeIfPresent(String.self, forKey: .quote),
			markdown: container.decode(String.self, forKey: .markdown),
			assessment: container.decodeIfPresent(Assessment.self, forKey: .assessment),
			objection: container.decodeIfPresent(String.self, forKey: .objection),
			isKey: container.decodeIfPresent(Bool.self, forKey: .isKey) ?? false,
			basis: decoded
		)
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: Key.self)
		try container.encode(id, forKey: .id)
		try container.encode(board, forKey: .board)
		try container.encode(run, forKey: .run)
		try container.encode(target, forKey: .target)
		try container.encode(citation, forKey: .citation)
		try container.encodeIfPresent(quote, forKey: .quote)
		try container.encode(markdown, forKey: .markdown)
		try container.encodeIfPresent(assessment, forKey: .assessment)
		try container.encodeIfPresent(objection, forKey: .objection)
		if isKey {
			try container.encode(isKey, forKey: .isKey)
		}
		try container.encode(Dictionary(uniqueKeysWithValues: basis.map { ($0.key.uuidString, $0.value) }), forKey: .basis)
	}
}

public struct BoardAnalysisStatus: Codable, Sendable, Hashable {
	public enum State: String, Codable, Sendable { case running, finished, failed, cancelled }

	/// A `running` status not heard from for longer than this means the server restarted under it
	public static let staleAfter: TimeInterval = 20 * 60

	public let board: UUID
	public let run: UUID
	public let state: State
	public let started: Date
	public let finished: Date?

	/// Worded like a compiler diagnostic, for showing
	public let error: String?

	/// Markdown
	public let discussion: String?

	/// When a `running` run last said it's still going, as a run in parts does before each part. Nil before then, and
	/// from a server that doesn't, so `started` is the last word.
	public let heartbeat: Date?

	public init(board: UUID, run: UUID, state: State, started: Date, finished: Date? = nil, error: String? = nil, discussion: String? = nil, heartbeat: Date? = nil) {
		self.board = board
		self.run = run
		self.state = state
		self.started = started
		self.finished = finished
		self.error = error
		self.discussion = discussion
		self.heartbeat = heartbeat
	}

	/// Running without a word for longer than `staleAfter`, so the server must have restarted under it
	public func isInterrupted(at now: Date) -> Bool {
		state == .running && now.timeIntervalSince(max(started, heartbeat ?? started)) > Self.staleAfter
	}
}

// MARK: - Records

/// Written by the server with one encoder every time, like the app's `SyncCoding`, which ErgoSync can't see
private enum ServerCoding {
	static var encoder: JSONEncoder {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys]
		encoder.dateEncodingStrategy = .iso8601
		return encoder
	}

	static var decoder: JSONDecoder {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		return decoder
	}

	static func fields(board: UUID, content: some Encodable) -> [String: JSONValue] {
		[
			SyncFieldName.board: .string(board.uuidString),
			SyncFieldName.content: (try? JSONValue(content, encoder: encoder)) ?? .null,
		]
	}

	static func content<Value: Decodable>(_ record: SyncRecord) -> Value? {
		guard !record.isDeleted else { return nil }
		return try? record.fields[SyncFieldName.content]?.value.decode(Value.self, decoder: decoder)
	}
}

public extension BoardAnnotation {
	/// The record's id: the annotation's own, uppercase
	var recordID: String {
		id.uuidString
	}

	/// Nil for another kind, a tombstone, or content this version can't read
	init?(_ record: SyncRecord) {
		guard record.kind == .annotation, let annotation: BoardAnnotation = ServerCoding.content(record), annotation.recordID == record.id else {
			return nil
		}
		self = annotation
	}

	/// What the server writes, for a record of kind `annotation`
	var fields: [String: JSONValue] {
		ServerCoding.fields(board: board, content: self)
	}
}

public extension BoardAnalysisStatus {
	/// The record's id: the board's, uppercase
	var recordID: String {
		board.uuidString
	}

	/// Nil for another kind, a tombstone, or content this version can't read
	init?(_ record: SyncRecord) {
		guard record.kind == .analysis, let status: BoardAnalysisStatus = ServerCoding.content(record), status.recordID == record.id else {
			return nil
		}
		self = status
	}

	/// What the server writes, for a record of kind `analysis`
	var fields: [String: JSONValue] {
		ServerCoding.fields(board: board, content: self)
	}
}
