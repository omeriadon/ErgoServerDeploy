//
//  AccountAuthenticator.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoProtocol
import Fluent
import Vapor

/// Signs the request in from its bearer token, or turns it away. Runs before a socket upgrades, so a bad token gets a plain 401.
/// A dead token is logged as a warning by `RequestLogMiddleware`, with nothing to say whose it was.
struct AccountAuthenticator: AsyncMiddleware {
	func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
		guard let bearer = request.headers.bearerAuthorization?.token else {
			throw ServiceError.unknownAccount
		}

		let hash = Account.hash(bearer)
		guard let token = try await AccountToken.query(on: request.db).filter(\.$tokenHash == hash).with(\.$account).first(),
		      token.matches(tokenHash: hash)
		else {
			throw ServiceError.unknownAccount
		}
		let account = token.account

		// Often enough to tell abandoned devices apart, without a write on every request
		let now = Date.now
		if token.lastSeen.distance(to: now) > 60 * 60 {
			token.lastSeen = now
			try await token.save(on: request.db)
		}
		if account.lastSeen.distance(to: now) > 60 * 60 {
			account.lastSeen = now
			try await account.save(on: request.db)
		}

		request.auth.login(account)
		request.auth.login(token)
		// From here on this request's logger is the account's: everything but problems is only for a verbose account
		request.identify(account)
		return try await next.respond(to: request)
	}
}

/// Turns away anonymous accounts, those with neither an Apple ID nor an email. Behind `AccountAuthenticator`,
/// and before a socket upgrades, so it can still say why.
struct RequireSignedIn: AsyncMiddleware {
	func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
		guard request.auth.get(Account.self)?.isSignedIn == true else {
			throw ServiceError.signInRequired
		}
		return try await next.respond(to: request)
	}
}

extension Request {
	/// Only behind `AccountAuthenticator`
	var accountID: UUID {
		get throws {
			guard let id = auth.get(Account.self)?.id else {
				throw ServiceError.unknownAccount
			}
			return id
		}
	}

	/// The token this request came with, so one device can be told apart from the account's others
	var tokenID: UUID {
		get throws {
			guard let id = auth.get(AccountToken.self)?.id else {
				throw ServiceError.unknownAccount
			}
			return id
		}
	}
}
