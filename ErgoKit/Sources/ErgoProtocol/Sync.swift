//
//  Sync.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

// The sync body and reply (`SyncRequest`, `SyncResponse`, `SyncChange`, `SupersededField`) live in ErgoSync,
// since `SyncReplica` makes and applies them and ErgoSync has no dependencies. Re-exported so the wire protocol
// is all one import.
@_exported import ErgoSync
import Foundation

// MARK: - Sign in with Apple

/// Sent with this device's current token, so the server knows which account to attach or merge
public struct SignInWithAppleRequest: Codable, Sendable, Hashable {
	/// `ASAuthorizationAppleIDCredential.identityToken`, as UTF-8
	public let identityToken: String

	/// The raw nonce. The Apple request carried its SHA-256, which the server checks against the token's `nonce` claim.
	public let nonce: String

	/// `ASAuthorizationAppleIDCredential.authorizationCode`, as UTF-8. The server trades it with Apple for a refresh token,
	/// which it keeps only to revoke the sign-in when the account is deleted. Apple's code works once and expires in minutes.
	/// Nil from an app that doesn't send it, and then nothing can be revoked.
	public let authorizationCode: String?

	public init(identityToken: String, nonce: String, authorizationCode: String? = nil) {
		self.identityToken = identityToken
		self.nonce = nonce
		self.authorizationCode = authorizationCode
	}
}

public struct SignedIn: Codable, Sendable, Hashable {
	public let accountID: UUID

	/// This device's token from now on. Store it even when it's the one sent.
	public let token: String

	/// No account had this Apple ID, so this device's account became it. False when this device joined another
	/// device's account, whose data the next full sync brings down.
	public let isNewAccount: Bool

	public init(accountID: UUID, token: String, isNewAccount: Bool) {
		self.accountID = accountID
		self.token = token
		self.isNewAccount = isNewAccount
	}
}

// MARK: - Live

/// What the sync socket sends. It never tells the device that pushed, only the account's other devices and the other
/// members of a shared board it pushed to.
public enum SyncLiveMessage: Codable, Sendable, Hashable {
	/// Another device or member pushed. Sync if `cursor` is ahead of this device's: it's this account's own seq.
	case changed(cursor: Int)
}
