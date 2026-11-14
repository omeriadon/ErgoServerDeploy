//
//  Account.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import Crypto
import Fluent
import Foundation
import Vapor

/// Anonymous until it signs in with Apple or an email and password, which is what lets several devices share it.
/// It can have both. It has one token per device.
final class Account: Model, Authenticatable, @unchecked Sendable {
	static let schema = "accounts"

	@ID(key: .id)
	var id: UUID?

	@Field(key: "created")
	var created: Date

	@Field(key: "last_seen")
	var lastSeen: Date

	/// The Apple ID's `sub`, the same on every device. Nil while anonymous, and sync needs it.
	@OptionalField(key: "apple_subject")
	var appleSubject: String?

	/// Apple's refresh token for this sign-in, sealed by `CredentialVault`. Kept only to revoke the sign-in when the account is
	/// deleted, never used to sign anyone in. Nil without `ERGO_APPLE_SIGNIN_KEY`, before the app sent a code, and for accounts
	/// that signed in before this existed. Never leaves the server.
	@OptionalField(key: "apple_refresh_token")
	var appleRefreshToken: Data?

	/// Lowercased and trimmed, the same on every device. Kept in the clear because it's what a login looks up,
	/// and never logged. Nil until registered. Not verified, since there's no mail provider yet.
	@OptionalField(key: "email")
	var email: String?

	/// bcrypt, always set with `email`. Never leaves the server.
	@OptionalField(key: "password_hash")
	var passwordHash: String?

	/// The last sync change number. Every changed record takes the next one, so a cursor is just a number.
	@Field(key: "seq")
	var seq: Int

	/// The highest seq pruning removed. A cursor below it may have missed a delete.
	@Field(key: "pruned_through")
	var prunedThrough: Int

	@Children(for: \.$account)
	var tokens: [AccountToken]

	@Children(for: \.$account)
	var credentials: [Credential]

	init() {}

	init(now: Date = .now) {
		created = now
		lastSeen = now
		seq = 0
		prunedThrough = 0
	}

	/// Either way back in counts, and sync needs one
	var isSignedIn: Bool {
		appleSubject != nil || email != nil
	}

	// MARK: - Tokens

	/// 32 random bytes, base64url
	static func makeToken() -> String {
		base64URL(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
	}

	static func hash(_ token: String) -> String {
		base64URL(Data(SHA256.hash(data: Data(token.utf8))))
	}

	private static func base64URL(_ data: Data) -> String {
		data.base64EncodedString()
			.replacingOccurrences(of: "+", with: "-")
			.replacingOccurrences(of: "/", with: "_")
			.replacingOccurrences(of: "=", with: "")
	}
}
