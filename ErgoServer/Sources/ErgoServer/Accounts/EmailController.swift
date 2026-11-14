//
//  EmailController.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoProtocol
import Fluent
import Vapor

/// `POST v1/account/register`, `POST v1/account/login` and `POST v1/account/password`
///
/// Passwords are only ever hashed and checked by bcrypt on the thread pool, never on an event loop, and are never
/// logged or sent back. Emails aren't logged either.
enum EmailController {
	// MARK: - Register

	/// Attaches an email and password to this device's account, so it can be reached again from another device
	static func register(_ request: Request) async throws -> Response {
		let body = try request.decode(EmailCredentials.self)
		guard request.ergo.registerLimiter.allow(request.clientAddress) else {
			throw ServiceError(code: .rateLimited, message: "Too many registrations from this address, try again in an hour")
		}

		let email = try AccountEmail.normalized(body.email)
		try AccountPassword.check(body.password)
		let hash = try await request.password.async.hash(body.password).get()

		let callerID = try request.accountID
		do {
			try await request.quietDB.transaction { database in
				let caller = try await SyncService.lock(callerID, on: database)
				guard caller.email == nil else {
					throw ServiceError(code: .invalidRequest, message: "Already signed in with an email, sign out first")
				}
				guard try await Account.query(on: database).filter(\.$email == email).first() == nil else {
					throw ServiceError.emailInUse
				}
				caller.email = email
				caller.passwordHash = hash
				try await caller.save(on: database)
			}
		} catch let error as any DatabaseError where error.isConstraintFailure {
			// Two registrations of one email at once, the unique index has the last word
			throw ServiceError.emailInUse
		}

		// The account may be one of the configured ones, now that it has an email to say so
		request.identify(attaching: email, to: callerID)
		request.logger.verbose("Registered an email")
		return Response(status: .noContent)
	}

	// MARK: - Log in

	/// Merges this device's anonymous account into the one that owns the email, like Sign in with Apple does
	static func logIn(_ request: Request) async throws -> Response {
		let body = try request.decode(EmailCredentials.self)
		let limiter = request.ergo.loginLimiter
		let address = request.clientAddress
		let email = try AccountEmail.normalized(body.email)
		try throttle(limiter, address: address, email: email)

		let target = try await Account.query(on: request.quietDB).filter(\.$email == email).first()
		let isRight = try await verify(body.password, against: target?.passwordHash, on: request)
		guard let target, isRight else {
			limiter.fail(address: address, email: email)
			throw ServiceError.invalidCredentials
		}
		limiter.succeed(email: email)

		guard let bearer = request.headers.bearerAuthorization?.token else {
			throw ServiceError.unknownAccount
		}
		let callerID = try request.accountID
		let tokenID = try request.tokenID
		let targetID = try target.requireID()
		let merger = AccountMerger(vault: request.ergo.vault, logger: request.logger)

		let changedCursor = try await request.quietDB.transaction { database -> Int? in
			let caller = try await SyncService.lock(callerID, on: database)
			if callerID == targetID {
				return nil
			}
			// Signed in already, as someone else. Merging would lose one of the two.
			guard !caller.isSignedIn else {
				throw ServiceError(code: .invalidRequest, message: "Already signed in with another account, sign out first")
			}
			// The caller's lock is a write lock, so the target can't have gone since it was found, but the lookup is cheap
			guard try await Account.find(targetID, on: database) != nil else {
				throw ServiceError.invalidCredentials
			}
			let target = try await SyncService.lock(targetID, on: database)
			guard let token = try await AccountToken.find(tokenID, on: database) else {
				throw ServiceError.unknownAccount
			}
			let changed = try await merger.merge(caller, into: target, token: token, on: database)
			return changed ? target.seq : nil
		}

		if let changedCursor {
			request.ergo.live.changed(account: targetID, cursor: changedCursor, except: tokenID)
		}
		// After a merge the account is the one that owns the email, which may be verbose when the caller's was not
		await request.identify(targetID)
		request.logger.verbose("Signed in with an email", metadata: ["merged": "\(targetID != callerID)"])
		return try Response.json(SignedIn(accountID: targetID, token: bearer, isNewAccount: false))
	}

	// MARK: - Change password

	/// Signs every other device out, so a lost one can't carry on. This device's token stays.
	static func changePassword(_ request: Request) async throws -> Response {
		let body = try request.decode(ChangePasswordRequest.self)
		try AccountPassword.check(body.new)

		let accountID = try request.accountID
		let tokenID = try request.tokenID
		guard let account = try await Account.find(accountID, on: request.quietDB), let email = account.email, let current = account.passwordHash else {
			throw ServiceError(code: .invalidRequest, message: "Expected an account with an email, found none, register one first")
		}

		// Guessing the current password with a stolen token is the same attack as guessing at a login
		let limiter = request.ergo.loginLimiter
		let address = request.clientAddress
		try throttle(limiter, address: address, email: email)
		guard try await verify(body.current, against: current, on: request) else {
			limiter.fail(address: address, email: email)
			throw ServiceError(code: .invalidCredentials, message: "Expected the current password of this account, found another")
		}
		limiter.succeed(email: email)

		let hash = try await request.password.async.hash(body.new).get()
		let revoked = try await request.quietDB.transaction { database -> [UUID] in
			let account = try await SyncService.lock(accountID, on: database)
			account.passwordHash = hash
			try await account.save(on: database)

			let others = try await AccountToken.query(on: database).filter(\.$account.$id == accountID).filter(\.$id != tokenID).all()
			try await AccountToken.query(on: database).filter(\.$account.$id == accountID).filter(\.$id != tokenID).delete()
			return others.compactMap(\.id)
		}
		for token in revoked {
			request.ergo.live.close(token: token, account: accountID)
		}

		request.logger.verbose("Changed a password", metadata: ["signedOut": "\(revoked.count)"])
		return Response(status: .noContent)
	}

	// MARK: - Passwords

	/// With no hash, a made-up one is checked instead and the answer is false, so an unknown email takes as long
	/// as a wrong password and the response doesn't say which emails have accounts. A password that couldn't have
	/// been stored is checked too, and refused after, since bcrypt would only read its first 72 bytes.
	private static func verify(_ password: String, against hash: String?, on request: Request) async throws -> Bool {
		let couldMatch = hash != nil && (try? AccountPassword.check(password)) != nil
		let matches = try await request.password.async.verify(password, created: hash ?? request.ergo.dummyPasswordHash).get()
		return couldMatch && matches
	}

	private static func throttle(_ limiter: LoginLimiter, address: String, email: String) throws {
		if let wait = limiter.wait(address: address, email: email) {
			throw ServiceError(code: .rateLimited, message: "Too many failed sign-ins, try again in \(LoginLimiter.describe(wait: wait))")
		}
	}
}

extension Request {
	/// The database without Fluent's debug log, which prints every value of every query, so an email and a password
	/// hash would be in it. Only the email routes touch those.
	var quietDB: any Database {
		var logger = logger
		logger.logLevel = max(logger.logLevel, .info)
		return db(nil, logger: logger)
	}
}

extension ServiceError {
	/// The same words for an unknown email and a wrong password
	static let invalidCredentials = ServiceError(code: .invalidCredentials, message: "Expected the email and password of an account, found none that match")
	static let emailInUse = ServiceError(code: .emailInUse, message: "Expected an unused email, found one that has an account")
}
