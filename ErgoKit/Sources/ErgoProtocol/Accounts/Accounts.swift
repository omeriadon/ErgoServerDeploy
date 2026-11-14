//
//  Accounts.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import Foundation

/// Anonymous, one per install
public struct AccountCreated: Codable, Sendable, Hashable {
	public let id: UUID

	/// Bearer token for every other request. Shown once, the server only keeps its hash.
	public let token: String

	public init(id: UUID, token: String) {
		self.id = id
		self.token = token
	}
}

// MARK: - Email and password

/// Sent with this device's current token. To register it attaches the email and password to the device's account,
/// to log in it joins the account that has them.
public struct EmailCredentials: Codable, Sendable, Hashable {
	public let email: String
	public let password: String

	public init(email: String, password: String) {
		self.email = email
		self.password = password
	}
}

/// Sent by a device whose account has an email. Every other device of the account is signed out.
public struct ChangePasswordRequest: Codable, Sendable, Hashable {
	public let current: String
	public let new: String

	public init(current: String, new: String) {
		self.current = current
		self.new = new
	}
}

// MARK: - Shapes

/// What an email may look like. The server checks with this, and the app can before sending.
public enum AccountEmail {
	public static let maxBytes = 254

	/// Trimmed and lowercased, so "Ada@Example.com " and "ada@example.com" are the same account.
	/// Throws a `ServiceError` worded for the user.
	public static func normalized(_ email: String) throws -> String {
		let email = email.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()

		guard email.utf8.count <= maxBytes else {
			throw ServiceError(code: .invalidRequest, message: "Expected an email of at most \(maxBytes) bytes, found \(email.utf8.count)")
		}

		let parts = email.split(separator: "@", omittingEmptySubsequences: false)
		let isOrdinary = !email.unicodeScalars.contains { $0.properties.isWhitespace || $0.properties.generalCategory == .control }
		guard parts.count == 2, !parts[0].isEmpty, isOrdinary, isDomain(parts[1]) else {
			throw ServiceError(code: .invalidRequest, message: "Expected an email like 'name@example.com', found '\(shortened(email))'")
		}
		return email
	}

	/// A dot inside it, so "localhost" and "example." are out
	private static func isDomain(_ domain: Substring) -> Bool {
		domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".") && !domain.contains("..")
	}

	private static func shortened(_ text: String) -> String {
		text.count > 64 ? text.prefix(64) + "…" : text
	}
}

/// How long a password may be. bcrypt only reads the first 72 bytes, so a longer one would be quietly cut short.
public enum AccountPassword {
	public static let minBytes = 10
	public static let maxBytes = 72

	/// Counted in UTF-8 bytes, not characters. Throws a `ServiceError` worded for the user.
	public static func check(_ password: String) throws {
		let bytes = password.utf8.count
		guard (minBytes ... maxBytes).contains(bytes) else {
			throw ServiceError(code: .invalidRequest, message: "Expected a password of \(minBytes) to \(maxBytes) bytes, found \(bytes)")
		}
		// bcrypt stops reading at the first NUL
		guard !password.utf8.contains(0) else {
			throw ServiceError(code: .invalidRequest, message: "Expected a password without NUL characters")
		}
	}
}
