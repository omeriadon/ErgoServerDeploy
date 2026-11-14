//
//  ServiceError.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import Foundation

/// Everything that can go wrong talking to the server, and the only error `ErgoClient` throws
public struct ServiceError: Error, Codable, Sendable, Hashable {
	public enum Code: String, Codable, Sendable {
		/// A code newer than this app reads as `internalError`, so a new one needs no protocol version
		public init(from decoder: any Decoder) throws {
			self = try Self(rawValue: decoder.singleValueContainer().decode(String.self)) ?? .internalError
		}

		/// Missing or unknown account token
		case unauthorized

		/// Protocol or grammar version mismatch
		case outdatedApp

		case invalidRequest

		/// No credential for that provider
		case notConnected

		/// The provider says the credential is invalid or expired
		case credentialRejected

		/// The provider's rate or plan limit
		case usageLimit

		/// Today's allowance on Ergo's model has been used
		case allowanceUsed

		/// Only on the paid plan
		case planRequired

		/// CLI missing, crashed, network, provider outage
		case providerUnavailable

		/// This account already has a translation running
		case busy

		case timedOut
		case internalError

		/// Sync needs an account signed in, with Apple or an email: "Sign in to sync"
		case signInRequired

		/// The server pruned tombstones this device hasn't seen. `SyncReplica.reset()`, then sync again.
		case syncResetRequired

		/// Too many requests for this account, try again later
		case rateLimited

		/// Over a sync limit: "Expected a board under 256 KB, found 300 KB"
		case tooLarge

		/// A wrong email or password, the same for both so it can't be used to find out which emails have accounts.
		/// Not `unauthorized`, which means this device's token is dead and the app signs out.
		case invalidCredentials

		/// The email already has an account: "Expected an unused email, found one that has an account". The app can offer to sign in instead.
		case emailInUse
	}

	public let code: Code

	/// Compiler-style, shown to the user as is: "Claude isn't connected", "Expected Ergo 1.2 or later"
	public let message: String

	public init(code: Code, message: String) {
		self.code = code
		self.message = message
	}
}

extension ServiceError: LocalizedError {
	public var errorDescription: String? {
		message
	}
}
