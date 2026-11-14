//
//  AppleNotificationController.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoProtocol
import Fluent
import Vapor

/// `POST v1/apple/notifications`, Sign in with Apple's server-to-server notifications. Apple calls it, not the app,
/// so it has no token and no protocol version.
///
/// A verified notification always gets an empty `200`, even about nobody or a second time, or Apple keeps retrying.
/// Only the event type and whether an account matched are logged, and only for a verbose account (`VerboseAccounts`) whose
/// notification it was: this route has no account of its own. Never the `sub`, an email or the payload.
enum AppleNotificationController {
	/// Registered in the developer portal as `https://<host>/v1/apple/notifications`, so it can't change
	static let path = "v1/apple/notifications"

	/// A notification is a JWT of about a kilobyte
	static let maxBytes = 16 * 1024

	/// The one request `ProtocolVersionMiddleware` lets through without the header
	static func isNotification(_ request: Request) -> Bool {
		request.method == .POST && request.url.path.split(separator: "/") == path.split(separator: "/")
	}

	static func receive(_ request: Request) async throws -> Response {
		guard request.ergo.appleNotificationLimiter.allow(request.clientAddress) else {
			throw ServiceError(code: .rateLimited, message: "Too many notifications from this address, try again in a minute")
		}
		// The route only enforces its limit for a body that arrives over the wire
		if let bytes = request.body.data?.readableBytes, bytes > maxBytes {
			throw ServiceError(code: .tooLarge, message: "Expected a notification under \(maxBytes / 1024) KB, found \((bytes + 1023) / 1024) KB")
		}
		guard let payload = payload(of: request) else {
			throw ServiceError.invalidNotification
		}
		let notification = try await request.ergo.apple.notification(payload, on: request)

		// Already handled, and Apple didn't hear back, or someone is replaying it
		let seen = request.ergo.appleNotifications
		guard seen.insert(notification.id) else {
			// Apple was answered, so this is a replay or Apple sending it twice
			if let leftOut = request.ergo.logThrottle.allow("Apple notification repeated") {
				request.logger.warning("Apple notification already handled", metadata: ["type": "\(notification.event.type)", "leftOut": "\(leftOut)"])
			}
			return Response(status: .ok)
		}

		let handled: Handled
		do {
			handled = try await handle(notification, on: request)
		} catch {
			seen.forget(notification.id)
			throw error
		}

		var metadata: Logger.Metadata = ["type": "\(notification.event.type)"]
		if let matched = handled.matched {
			metadata["matched"] = "\(matched)"
		}
		if case .unknown = notification.event {
			// Apple has a new kind, which nothing here knows to act on
			request.logger.warning("Unknown Apple notification", metadata: metadata)
		} else if let account = handled.account {
			request.ergo.verbose.logger(for: account, from: request.logger).verbose("Apple notification", metadata: metadata)
		}
		return Response(status: .ok)
	}

	/// JSON `{"payload": "<JWT>"}`, or the same as a form, in case Apple ever posts one
	private static func payload(of request: Request) -> String? {
		struct Body: Decodable {
			let payload: String
		}

		let body = request.headers.contentType == .urlEncodedForm
			? try? request.content.decode(Body.self, as: .urlEncodedForm)
			: try? request.decode(Body.self)
		guard let payload = body?.payload, !payload.isEmpty else { return nil }
		return payload
	}

	// MARK: - Events

	/// What a notification did
	private struct Handled {
		/// Whether an account had the `sub`, or nil when none was looked for
		var matched: Bool?

		/// The account that had it, to say so to its own log if it's a verbose one
		var account: UUID?
	}

	private static func handle(_ notification: AppleNotification, on request: Request) async throws -> Handled {
		switch notification.event {
			// The relay address is never stored, so there's nothing to change
			case .emailEnabled, .emailDisabled:
				Handled()
			case .consentRevoked:
				try await signOut(notification.subject, on: request)
			case .accountDelete:
				try await forget(notification.subject, on: request)
			case .unknown:
				Handled()
		}
	}

	/// The user stopped using Sign in with Apple with Ergo. Every device is signed out on its next request, but the
	/// Apple ID and the data stay, so signing in with Apple again gets back to them.
	private static func signOut(_ subject: String, on request: Request) async throws -> Handled {
		// The quiet handle, since Fluent's debug log would print the `sub`
		let database = request.quietDB
		guard let id = try await Account.query(on: database).filter(\.$appleSubject == subject).first()?.requireID() else {
			return Handled(matched: false)
		}
		try await AccountToken.query(on: database).filter(\.$account.$id == id).delete()
		request.ergo.live.close(account: id)
		return Handled(matched: true, account: id)
	}

	/// The Apple ID is gone for good, so it can never sign in again. An account that also has an email keeps
	/// everything else. One that doesn't can't be reached any more, so it goes like `DELETE v1/account`.
	private static func forget(_ subject: String, on request: Request) async throws -> Handled {
		let database = request.quietDB
		guard let id = try await Account.query(on: database).filter(\.$appleSubject == subject).first()?.requireID() else {
			return Handled(matched: false)
		}

		let sharing = request.ergo.sharing
		let vault = request.ergo.vault
		let logger = request.logger
		let others = try await sharing.accounts(sharingWith: id, on: database)
		let (deleted, effects) = try await database.transaction { database -> (Bool?, BoardLedger.Effects) in
			// Everyone it shares a board with, in order, in case it goes
			try await BoardLedger.lockInOrder(others + [id], on: database)
			let account: Account
			do {
				account = try await SyncService.lock(id, on: database)
			} catch let error as ServiceError where error == .unknownAccount {
				// Deleted since it was found
				return (nil, BoardLedger.Effects())
			}
			guard account.appleSubject == subject else { return (nil, BoardLedger.Effects()) }

			guard account.email == nil else {
				account.appleSubject = nil
				// Apple has no sign-in left to revoke
				account.appleRefreshToken = nil
				try await account.save(on: database)
				return (false, BoardLedger.Effects())
			}
			let effects = try await AccountController.deleteEverything(of: id, vault: vault, logger: logger, on: database)
			return (true, effects)
		}

		if deleted == true {
			request.ergo.live.close(account: id)
			await sharing.finish(effects, caller: nil, token: nil, on: database, logger: logger)
		}
		return Handled(matched: deleted != nil, account: id)
	}
}
