//
//  Translate.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoTranslation
import Foundation

/// How much of the pipeline a request runs, and so which message ends it
public enum TranslateScope: String, Codable, Sendable, Hashable, CaseIterable {
	/// One statement: gate, breakdown, formalize and verify, ending in `TranslateServerMessage.finished`
	case statement

	/// A pasted argument: gate and breakdown only, ending in `BreakDownServerMessage.finished`
	case argument
}

public struct TranslateRequest: Codable, Sendable, Hashable {
	public let id: UUID
	public let english: String
	public let provider: Provider

	/// `LogicLetters.resolved`, so the model writes the letters the app shows
	public let letters: [String]
	public let grammarVersion: Int

	/// What the board already calls its letters, up to six, with an empty string for a slot nobody has named yet.
	/// Claims that match one keep that letter, and new claims only take free slots. Nil when the board names nothing.
	public var descriptors: [String]?

	public var scope: TranslateScope

	public init(
		id: UUID,
		english: String,
		provider: Provider,
		letters: [String],
		grammarVersion: Int,
		descriptors: [String]? = nil,
		scope: TranslateScope = .statement
	) {
		self.id = id
		self.english = english
		self.provider = provider
		self.letters = letters
		self.grammarVersion = grammarVersion
		self.descriptors = descriptors
		self.scope = scope
	}

	private enum CodingKeys: String, CodingKey {
		case id, english, provider, letters, grammarVersion, descriptors, scope
	}

	/// `descriptors` and `scope` are missing from requests an older app makes
	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		try self.init(
			id: container.decode(UUID.self, forKey: .id),
			english: container.decode(String.self, forKey: .english),
			provider: container.decode(Provider.self, forKey: .provider),
			letters: container.decode([String].self, forKey: .letters),
			grammarVersion: container.decode(Int.self, forKey: .grammarVersion),
			descriptors: container.decodeIfPresent([String].self, forKey: .descriptors),
			scope: container.decodeIfPresent(TranslateScope.self, forKey: .scope) ?? .statement
		)
	}
}

public enum TranslateClientMessage: Codable, Sendable, Hashable {
	case translate(TranslateRequest)
	case cancel
}

/// What a `.statement` request hears
public enum TranslateServerMessage: Codable, Sendable, Hashable {
	case event(TranslationEvent)
	case finished(Translation)
	case failed(ServiceError)
}

/// What an `.argument` request hears. A separate type from `TranslateServerMessage` so that one stays exhaustive for
/// every app that only translates statements. `.event` and `.failed` code exactly like theirs.
public enum BreakDownServerMessage: Codable, Sendable, Hashable {
	case event(TranslationEvent)
	case finished(ArgumentBreakdown)
	case failed(ServiceError)
}
