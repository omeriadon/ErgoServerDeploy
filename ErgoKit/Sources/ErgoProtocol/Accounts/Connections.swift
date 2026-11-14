//
//  Connections.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import Foundation

/// At most one credential per provider, so uploading replaces whatever was there
public struct ConnectionUpload: Codable, Sendable, Hashable {
	public let kind: CredentialKind
	public let secret: String

	public init(kind: CredentialKind, secret: String) {
		self.kind = kind
		self.secret = secret
	}
}

public struct ConnectionStatus: Codable, Sendable, Hashable {
	public let provider: Provider
	public let kind: CredentialKind

	/// When a test call last succeeded with this credential
	public let verified: Date?

	/// Why the last call failed, worded like a compiler error. Nil when it's working.
	public let problem: String?

	public init(provider: Provider, kind: CredentialKind, verified: Date?, problem: String?) {
		self.provider = provider
		self.kind = kind
		self.verified = verified
		self.problem = problem
	}
}

/// What the server sends while running `codex login --device-auth` for the user
public enum DeviceLoginMessage: Codable, Sendable, Hashable {
	/// Open `url` in a browser and enter `code`
	case code(url: URL, code: String)
	case connected(ConnectionStatus)
	case failed(ServiceError)
}
