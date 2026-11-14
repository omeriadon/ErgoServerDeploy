//
//  Ask.swift
//  ErgoKit
//
//  Created by Adon Omeri on 6/11/2026.
//

import Foundation

// MARK: - Request

/// One turn of a conversation. The server stores nothing between turns, so `messages` is all of it, ending with the user.
/// `id` names the run: the server answers it whether or not the connection lasts, and a request with an id it already has
/// joins that run instead of starting another.
public struct AskRequest: Codable, Sendable, Hashable {
	public static let characterLimit = 200_000

	public let id: UUID
	public let provider: Provider
	public let messages: [AskRequestMessage]

	/// What the person asked of the agent, like how concise to be. See `AgentInstructions`.
	public let instructions: String?

	/// Nil is `.normal`, and an older app says nothing
	public let mode: AskMode?

	/// The board this chat is about, as it is now
	public let board: AskBoard?

	public init(id: UUID, provider: Provider, messages: [AskRequestMessage], instructions: String? = nil, mode: AskMode = .normal, board: AskBoard? = nil) {
		self.id = id
		self.provider = provider
		self.messages = messages
		self.instructions = AgentInstructions.normalized(instructions)
		self.mode = mode == .normal ? nil : mode
		self.board = board
	}

	/// What's wrong with it, worded like a compiler diagnostic. Nil when it can be answered.
	public var problem: String? {
		guard messages.last?.role == .user else {
			return "Expected the last message to be the user's"
		}
		let characters = messages.reduce(board?.characters ?? 0) { $0 + $1.text.count }
		guard characters <= Self.characterLimit else {
			return "Expected a conversation of at most \(Self.characterLimit) characters, found \(characters)"
		}
		return AgentInstructions.problem(instructions)
	}
}

/// A few words from the person to the agent, about how to answer: how concise, what tone. Never about what counts
/// as a source or how to use the tools, so the server hands it over as a preference, after its own rules.
public enum AgentInstructions {
	public static let characterLimit = 1000

	/// Trimmed, and nil when there's nothing left
	public static func normalized(_ instructions: String?) -> String? {
		guard let trimmed = instructions?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
			return nil
		}
		return trimmed
	}

	/// What's wrong with it, worded like a compiler diagnostic. Nil when it can be used.
	public static func problem(_ instructions: String?) -> String? {
		let characters = instructions?.count ?? 0
		guard characters <= characterLimit else {
			return "Expected instructions of at most \(characterLimit) characters, found \(characters)"
		}
		return nil
	}
}

public struct AskRequestMessage: Codable, Sendable, Hashable {
	public enum Role: String, Codable, Sendable {
		case user, assistant
	}

	public let role: Role
	public let text: String

	public init(role: Role, text: String) {
		self.role = role
		self.text = text
	}
}

public enum AskClientMessage: Codable, Sendable, Hashable {
	case ask(AskRequest)
	case cancel
}

// MARK: - Reply

/// What the model is doing while it isn't writing
public struct AskToolActivity: Codable, Sendable, Hashable {
	public let tool: String

	/// "Searching the library for 'straw man'", for showing while it runs
	public let summary: String

	/// "Searched the library for 'straw man'", for showing afterwards
	public let record: String

	public init(tool: String, summary: String, record: String? = nil) {
		self.tool = tool
		self.summary = summary
		self.record = record ?? summary
	}

	private enum CodingKeys: String, CodingKey {
		case tool, summary, record
	}

	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		tool = try container.decode(String.self, forKey: .tool)
		summary = try container.decode(String.self, forKey: .summary)
		record = try container.decodeIfPresent(String.self, forKey: .record) ?? summary
	}
}

/// A message to the app. Coded by hand, so that a kind added later reaches an older app as `.unknown` and is skipped.
public enum AskServerMessage: Sendable, Hashable {
	/// More of the answer, to add to what's come so far
	case text(String)
	case tool(AskToolActivity)
	case action(AskAction)
	/// A short name for the chat, written once its first answer is done
	case title(String)
	/// The model asks to change the chat's mode, for the person to accept or turn down
	case modeRequest(AskModeRequest)
	/// A change to the board the chat is about, for the device to make
	case boardEdit(AskBoardEdit)
	case finished
	case failed(ServiceError)
	case unknown
}

extension AskServerMessage: Codable {
	private enum Key: String, CodingKey {
		case type, text, tool, action, error, mode, edit
	}

	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: Key.self)
		switch try container.decode(String.self, forKey: .type) {
			case "text":
				self = try .text(container.decode(String.self, forKey: .text))
			// None of these ends an answer, so one this version can't read is skipped like a kind it doesn't know
			case "tool":
				self = (try? container.decode(AskToolActivity.self, forKey: .tool)).map(Self.tool) ?? .unknown
			case "action":
				self = (try? container.decode(AskAction.self, forKey: .action)).map(Self.action) ?? .unknown
			case "title":
				self = (try? container.decode(String.self, forKey: .text)).map(Self.title) ?? .unknown
			case "modeRequest":
				self = (try? container.decode(AskModeRequest.self, forKey: .mode)).map(Self.modeRequest) ?? .unknown
			case "boardEdit":
				self = (try? container.decode(AskBoardEdit.self, forKey: .edit)).map(Self.boardEdit) ?? .unknown
			case "finished":
				self = .finished
			case "failed":
				self = try .failed(container.decode(ServiceError.self, forKey: .error))
			default:
				self = .unknown
		}
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: Key.self)
		switch self {
			case let .text(text):
				try container.encode("text", forKey: .type)
				try container.encode(text, forKey: .text)
			case let .tool(activity):
				try container.encode("tool", forKey: .type)
				try container.encode(activity, forKey: .tool)
			case let .action(action):
				try container.encode("action", forKey: .type)
				try container.encode(action, forKey: .action)
			case let .title(title):
				try container.encode("title", forKey: .type)
				try container.encode(title, forKey: .text)
			case let .modeRequest(request):
				try container.encode("modeRequest", forKey: .type)
				try container.encode(request, forKey: .mode)
			case let .boardEdit(edit):
				try container.encode("boardEdit", forKey: .type)
				try container.encode(edit, forKey: .edit)
			case .finished:
				try container.encode("finished", forKey: .type)
			case let .failed(error):
				try container.encode("failed", forKey: .type)
				try container.encode(error, forKey: .error)
			case .unknown:
				try container.encode("unknown", forKey: .type)
		}
	}
}

// MARK: - Actions

/// Something only the device can do: run one of the app's intents. A link in an answer and a button under it are both
/// this, so an intent's URL is how the model writes one into markdown and how a button travels.
public enum AskIntent: Sendable, Hashable {
	case openLibraryEntry(category: String, id: String)
	case showLibraryList(category: String)
	case openBookmarks
	case openTab(String)

	/// Puts a question in the composer. It isn't sent, so the person can change it first.
	case askFollowUp(String)

	/// From a newer server, so this version has nothing to run
	case unknown(String)

	private static let scheme = "ergo"
	private static let host = "intent"

	public var url: URL? {
		var components = URLComponents()
		components.scheme = Self.scheme
		components.host = Self.host
		switch self {
			case let .openLibraryEntry(category, id):
				components.path = "/open-library-entry"
				components.queryItems = [URLQueryItem(name: "category", value: category), URLQueryItem(name: "id", value: id)]
			case let .showLibraryList(category):
				components.path = "/show-library-list"
				components.queryItems = [URLQueryItem(name: "category", value: category)]
			case .openBookmarks:
				components.path = "/open-bookmarks"
			case let .openTab(tab):
				components.path = "/open-tab"
				components.queryItems = [URLQueryItem(name: "tab", value: tab)]
			case let .askFollowUp(text):
				components.path = "/ask-follow-up"
				components.queryItems = [URLQueryItem(name: "text", value: text)]
			case let .unknown(text):
				return URL(string: text)
		}
		return components.url
	}

	/// Nil when it isn't one of these URLs at all, so it can be opened like any other link
	public init?(url: URL) {
		guard
			let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
			components.scheme == Self.scheme,
			components.host == Self.host
		else {
			return nil
		}
		func value(_ name: String) -> String? {
			components.queryItems?.first { $0.name == name }?.value
		}

		switch components.path {
			case "/open-library-entry":
				guard let category = value("category"), let id = value("id") else { fallthrough }
				self = .openLibraryEntry(category: category, id: id)
			case "/show-library-list":
				guard let category = value("category") else { fallthrough }
				self = .showLibraryList(category: category)
			case "/open-bookmarks":
				self = .openBookmarks
			case "/open-tab":
				guard let tab = value("tab") else { fallthrough }
				self = .openTab(tab)
			case "/ask-follow-up":
				guard let text = value("text") else { fallthrough }
				self = .askFollowUp(text)
			default:
				self = .unknown(url.absoluteString)
		}
	}
}

/// A button under an answer
public struct AskAction: Codable, Sendable, Hashable {
	public let title: String
	public let intent: AskIntent

	public init(title: String, intent: AskIntent) {
		self.title = title
		self.intent = intent
	}

	private enum Key: String, CodingKey {
		case title, url
	}

	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: Key.self)
		title = try container.decode(String.self, forKey: .title)
		let text = try container.decode(String.self, forKey: .url)
		intent = URL(string: text).flatMap(AskIntent.init(url:)) ?? .unknown(text)
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: Key.self)
		try container.encode(title, forKey: .title)
		try container.encode(intent.url?.absoluteString ?? "", forKey: .url)
	}
}
