//
//  AccountController+AppleRefresh.swift
//  ErgoServer
//
//  Created by Adon Omeri on 10/11/2026.
//

import Fluent
import Vapor

/// Keeping Apple's refresh token, and revoking it when the account goes. Neither can fail what called it: a sign-in that
/// can't be revoked later is no reason to refuse it now, and an account must always be deletable. Logs say only how it
/// failed, never the code or a token.
extension AccountController {
	/// Codes are short, so anything longer isn't one
	static let maxAuthorizationCodeCharacters = 2048

	/// Trades the code for a refresh token and seals it onto the account that signed in, which after a merge is the
	/// surviving one. A newer token replaces an older one, so a user who revoked the old one in Settings is covered again.
	static func keepAppleRefreshToken(for account: UUID, code: String?, subject: String, on request: Request) async {
		let tokens = request.ergo.appleTokens
		guard tokens.isEnabled, let code, !code.isEmpty, code.count <= maxAuthorizationCodeCharacters else { return }

		do {
			let grant = try await tokens.exchange(code)
			// A code from another sign-in would have this account revoke someone else's
			if let granted = grant.subject, granted != subject {
				request.logger.warning("Apple's code was for another Apple ID, so its refresh token isn't kept")
				return
			}
			let sealed = try request.ergo.vault.seal(appleRefreshToken: grant.refreshToken, account: account)
			try await Account.query(on: request.quietDB).filter(\.$id == account).set(\.$appleRefreshToken, to: sealed).update()
		} catch {
			request.logger.warning("Couldn't keep Apple's refresh token, so this sign-in can't be revoked", metadata: ["reason": "\(AppleRefreshTokens.describe(error))"])
		}
	}

	/// Before the account's rows go, since the token is one of them
	static func revokeAppleSignIn(of account: UUID, on request: Request) async {
		let tokens = request.ergo.appleTokens
		guard tokens.isEnabled else { return }

		do {
			guard let sealed = try await Account.find(account, on: request.quietDB)?.appleRefreshToken else { return }
			try await tokens.revoke(request.ergo.vault.openAppleRefreshToken(sealed, account: account))
		} catch {
			request.logger.warning("Couldn't revoke the Sign in with Apple for a deleted account", metadata: ["reason": "\(AppleRefreshTokens.describe(error))"])
		}
	}
}
