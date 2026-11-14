//
//  Tolerant.swift
//  ErgoKit
//
//  Created by Adon Omeri on 11/11/2026.
//

import Foundation

// A newer server says things an older app has never heard of. Nothing here makes sense of them: it only lets the app
// carry on with what it does know. See `Plans/13-Versions.md`.

/// A list that leaves out what this version can't read, instead of failing altogether
public struct TolerantList<Element: Decodable>: Decodable {
	public let elements: [Element]

	public init(from decoder: any Decoder) throws {
		var container = try decoder.unkeyedContainer()
		var elements: [Element] = []
		while !container.isAtEnd {
			if let element = try? container.decode(Element.self) {
				elements.append(element)
			} else {
				// A failed decode doesn't move on, so the element is read as nothing
				_ = try container.decode(Skipped.self)
			}
		}
		self.elements = elements
	}

	private struct Skipped: Decodable {
		init(from _: any Decoder) throws {}
	}
}

extension TolerantList: Sendable where Element: Sendable {}

/// A socket message with named kinds, coded as an object with the kind as its one key. A frame that can't be read is
/// skipped when its kind is one this version doesn't know, or one that only reports progress. Anything else that can't
/// be read still ends the stream, since skipping the message a run ends with would wait for ever.
public protocol SkipsUnknownKinds {
	/// Every kind this version reads
	static var kinds: Set<String> { get }

	/// The kinds that never end a stream
	static var progressKinds: Set<String> { get }
}

public extension SkipsUnknownKinds {
	static var progressKinds: Set<String> {
		[]
	}

	/// Whether a frame that failed to decode can be passed over
	static func canSkip(_ frame: Data) -> Bool {
		guard let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any], object.count == 1, let kind = object.keys.first else {
			return false
		}
		return !kinds.contains(kind) || progressKinds.contains(kind)
	}
}

extension SyncLiveMessage: SkipsUnknownKinds {
	public static let kinds: Set<String> = ["changed"]
}

extension DeviceLoginMessage: SkipsUnknownKinds {
	public static let kinds: Set<String> = ["code", "connected", "failed"]
}

extension TranslateServerMessage: SkipsUnknownKinds {
	public static let kinds: Set<String> = ["event", "finished", "failed"]
	public static let progressKinds: Set<String> = ["event"]
}

extension BreakDownServerMessage: SkipsUnknownKinds {
	public static let kinds: Set<String> = ["event", "finished", "failed"]
	public static let progressKinds: Set<String> = ["event"]
}
