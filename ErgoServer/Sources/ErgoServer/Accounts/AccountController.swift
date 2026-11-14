//
//  AccountController.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoProtocol
import Fluent
import Vapor

/// `POST v1/accounts`, `DELETE v1/account`, `POST v1/account/apple` and `DELETE v1/account/token`.
/// The email routes are `EmailController`.
enum AccountController {
	static func create(_ request: Request) async throws -> Response {
		guard request.ergo.accountLimiter.allow(request.clientAddress) else {
			throw ServiceError(code: .usageLimit, message: "Too many new accounts from this address, try again in an hour")
		}

		let token = Account.makeToken()
		let id = try await request.db.transaction { database in
			let account = Account(now: .now)
			try await account.save(on: database)
			let id = try account.requireID()
			try await AccountToken(account: id, tokenHash: Account.hash(token)).save(on: database)
			return id
		}

		return try Response.json(AccountCreated(id: id, token: token))
	}

	/// Everything the server keeps for the account, on every device. Data on the devices stays. Its Sign in with Apple
	/// connection is revoked first, when the server has the means to.
	static func delete(_ request: Request) async throws -> Response {
		let id = try request.accountID
		await revokeAppleSignIn(of: id, on: request)
		let sharing = request.ergo.sharing
		let vault = request.ergo.vault
		let logger = request.logger
		let others = try await sharing.accounts(sharingWith: id, on: request.db)
		let effects = try await request.db.transaction { database in
			try await BoardLedger.lockInOrder(others + [id], on: database)
			return try await deleteEverything(of: id, vault: vault, logger: logger, on: database)
		}
		request.ergo.live.close(account: id)
		await sharing.finish(effects, caller: nil, token: nil, on: request.db, logger: logger)
		logger.verbose("Deleted the account", metadata: ["pushes": "\(effects.pushes.count)", "sharedWith": "\(others.count)"])
		return Response(status: .noContent)
	}

	/// The foreign keys cascade too, but SQLite only honours them when foreign keys are switched on.
	///
	/// Boards it owned go for everyone, and it leaves the others, which writes to those people's records. What to tell them
	/// comes back, for the caller to hand to `BoardSharing.finish` after committing. Only an account that's anonymous can
	/// be on no boards, so a caller deleting one of those can ignore it.
	@discardableResult
	static func deleteEverything(of account: UUID, vault: CredentialVault, logger: Logger, on database: any Database) async throws -> BoardLedger.Effects {
		var ledger = BoardLedger(vault: vault, logger: logger)
		try await ledger.removeAccount(account, on: database)
		let effects = try await ledger.finish(on: database)

		try await PushDeviceRow.query(on: database).filter(\.$account.$id == account).delete()
		try await UsagePeriodRow.query(on: database).filter(\.$account.$id == account).delete()
		try await AccountPlanRow.query(on: database).filter(\.$account.$id == account).delete()
		try await SyncRecordRow.query(on: database).filter(\.$account.$id == account).delete()
		try await AccountToken.query(on: database).filter(\.$account.$id == account).delete()
		try await Credential.query(on: database).filter(\.$account.$id == account).delete()
		try await Account.query(on: database).filter(\.$id == account).delete()
		return effects
	}

	// MARK: - Devices

	/// Forgets only this device's token. An anonymous account with no device left can't be reached again,
	/// so it goes too, connections and all.
	static func signOut(_ request: Request) async throws -> Response {
		let accountID = try request.accountID
		let tokenID = try request.tokenID
		let vault = request.ergo.vault
		let logger = request.logger
		try await request.db.transaction { database in
			try await AccountToken.query(on: database).filter(\.$id == tokenID).delete()

			let account = try await Account.find(accountID, on: database)
			let remaining = try await AccountToken.query(on: database).filter(\.$account.$id == accountID).count()
			if account?.isSignedIn == false, remaining == 0 {
				try await deleteEverything(of: accountID, vault: vault, logger: logger, on: database)
			}
		}
		request.ergo.live.close(token: tokenID, account: accountID)
		logger.verbose("Signed out a device")
		return Response(status: .noContent)
	}

	/// Attaches the Apple ID to this device's account, or merges this device's account into the one that already
	/// has it, all in one transaction. The device keeps its token either way.
	static func signInWithApple(_ request: Request) async throws -> Response {
		let body = try request.decode(SignInWithAppleRequest.self)
		let identity = try await request.ergo.apple(body.identityToken, on: request)
		try AppleTokenVerifier.check(identity, nonce: body.nonce)

		guard let bearer = request.headers.bearerAuthorization?.token else {
			throw ServiceError.unknownAccount
		}
		let callerID = try request.accountID
		let tokenID = try request.tokenID
		let merger = AccountMerger(vault: request.ergo.vault, logger: request.logger)

		let (accountID, isNewAccount, changedCursor) = try await request.quietDB.transaction { database -> (UUID, Bool, Int?) in
			let caller = try await SyncService.lock(callerID, on: database)
			let existing = try await Account.query(on: database).filter(\.$appleSubject == identity.subject).first()

			if let existing, existing.id == callerID {
				return (callerID, false, nil)
			}
			guard caller.appleSubject == nil else {
				throw ServiceError(code: .invalidRequest, message: "Already signed in with another Apple ID, sign out first")
			}
			guard let existing else {
				caller.appleSubject = identity.subject
				try await caller.save(on: database)
				return (callerID, true, nil)
			}
			// Another account's Apple ID, while this one is already someone by email
			guard caller.email == nil else {
				throw ServiceError(code: .invalidRequest, message: "Expected an Apple ID without an Ergo account, found one with its own, sign out to use it")
			}

			let targetID = try existing.requireID()
			let target = try await SyncService.lock(targetID, on: database)
			guard let token = try await AccountToken.find(tokenID, on: database) else {
				throw ServiceError.unknownAccount
			}
			let changed = try await merger.merge(caller, into: target, token: token, on: database)
			return (targetID, false, changed ? target.seq : nil)
		}

		if let changedCursor {
			request.ergo.live.changed(account: accountID, cursor: changedCursor, except: tokenID)
		}
		// After a merge the account is the one that was signed in to, which may be verbose when the caller's was not
		await request.identify(accountID)
		await keepAppleRefreshToken(for: accountID, code: body.authorizationCode, subject: identity.subject, on: request)
		request.logger.verbose("Signed in with Apple", metadata: ["merged": "\(accountID != callerID)", "new": "\(isNewAccount)"])
		return try Response.json(SignedIn(accountID: accountID, token: bearer, isNewAccount: isNewAccount))
	}
}
