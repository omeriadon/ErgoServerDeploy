//
//  SharedItemInbox.swift
//  ErgoKit
//
//  Created by Adon Omeri on 7/11/2026.
//

import Foundation

/// Where the share extension leaves an item for the app, since they're separate processes. Holds one: the newest share wins.
public struct SharedItemInbox: Sendable {
	public static let appGroup = "group.com.adonis.Ergo"

	/// Nil when the App Group entitlement is missing
	public static var shared: SharedItemInbox? {
		FileManager.default
			.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
			.map(SharedItemInbox.init(directory:))
	}

	private let file: URL

	public init(directory: URL) {
		file = directory.appending(path: "shared-item.json")
	}

	public func put(_ item: SharedItem) throws {
		try JSONEncoder().encode(item).write(to: file, options: .atomic)
	}

	/// The waiting item, which is gone from the inbox after this
	public func take() -> SharedItem? {
		guard let data = try? Data(contentsOf: file) else { return nil }
		try? FileManager.default.removeItem(at: file)
		return try? JSONDecoder().decode(SharedItem.self, from: data)
	}
}
