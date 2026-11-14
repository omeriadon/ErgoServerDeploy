//
//  AppleNotifications.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import Foundation
import JWT
import Synchronization

/// What Apple signs for a Sign in with Apple server-to-server notification. Only checked for its signature here,
/// the rest is `AppleNotification`'s, against the server's clock and app id.
struct AppleNotificationClaims: JWTPayload {
	let iss: IssuerClaim
	let aud: AudienceClaim
	let iat: IssuedAtClaim
	let jti: IDClaim

	/// JSON inside a string
	let events: String

	func verify(using _: some JWTAlgorithm) async throws {}
}

/// A notification whose signature, issuer, audience and age have all been checked
struct AppleNotification: Sendable, Hashable {
	enum Event: Sendable, Hashable {
		case emailEnabled
		case emailDisabled
		case consentRevoked
		case accountDelete
		case unknown(String)

		init(type: String) {
			switch type {
				case "email-enabled": self = .emailEnabled
				case "email-disabled": self = .emailDisabled
				case "consent-revoked": self = .consentRevoked
				case "account-delete": self = .accountDelete
				default: self = .unknown(type)
			}
		}

		/// Apple's name for it, short enough to log
		var type: String {
			switch self {
				case .emailEnabled: "email-enabled"
				case .emailDisabled: "email-disabled"
				case .consentRevoked: "consent-revoked"
				case .accountDelete: "account-delete"
				case let .unknown(type): type.count > 64 ? type.prefix(64) + "…" : type
			}
		}
	}

	/// The `jti`, for replay protection
	let id: String
	let event: Event

	/// The Apple ID's `sub`, as in `Account.appleSubject`. Never logged.
	let subject: String

	static let issuer = "https://appleid.apple.com"

	/// Apple retries for a while, but a day is plenty, and it bounds how long a `jti` has to be remembered
	static let maxAge: TimeInterval = 24 * 60 * 60

	/// For a server clock a little behind Apple's
	static let leeway: TimeInterval = 5 * 60

	/// Why a notification was refused, only for the server's own log, since it doesn't say who it was about
	struct Refusal: Error, CustomStringConvertible {
		let description: String
	}

	init(_ claims: AppleNotificationClaims, applicationIdentifier: String, now: Date = .now) throws(Refusal) {
		guard claims.iss.value == Self.issuer else {
			throw Refusal(description: "issuer")
		}
		guard claims.aud.value.contains(applicationIdentifier) else {
			throw Refusal(description: "audience")
		}
		let age = now.timeIntervalSince(claims.iat.value)
		guard age >= -Self.leeway else {
			throw Refusal(description: "issued in the future")
		}
		guard age <= Self.maxAge else {
			throw Refusal(description: "too old")
		}
		guard !claims.jti.value.isEmpty else {
			throw Refusal(description: "no jti")
		}

		// Only what's acted on is read, so `email`, `is_private_email` (a bool or a string) and `event_time` can be anything
		struct Events: Decodable {
			let type: String
			let sub: String
		}
		guard let events = try? JSONDecoder().decode(Events.self, from: Data(claims.events.utf8)), !events.sub.isEmpty else {
			throw Refusal(description: "events")
		}

		id = claims.jti.value
		event = Event(type: events.type)
		subject = events.sub
	}
}

/// The `jti`s of notifications already handled, so a replay changes nothing. Kept for 25 hours, a day being the
/// oldest `iat` accepted, plus slack. In memory, so a restart forgets, and a notification from the day before
/// could be handled again.
final class SeenNotifications: Sendable {
	let window: TimeInterval
	private let seen = Mutex<[String: Date]>([:])

	init(window: TimeInterval = 25 * 60 * 60) {
		self.window = window
	}

	/// False if it was seen already, otherwise remembers it
	func insert(_ id: String, now: Date = .now) -> Bool {
		seen.withLock { seen in
			// Forget what's past the window, so the table can't grow forever
			seen = seen.filter { now.timeIntervalSince($0.value) < window }
			guard seen[id] == nil else { return false }
			seen[id] = now
			return true
		}
	}

	/// When handling failed, so Apple's retry is handled
	func forget(_ id: String) {
		seen.withLock { $0[id] = nil }
	}
}
