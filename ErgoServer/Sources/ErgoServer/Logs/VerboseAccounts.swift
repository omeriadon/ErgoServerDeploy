//
//  VerboseAccounts.swift
//  ErgoServer
//
//  Created by Adon Omeri on 10/11/2026.
//

import Crypto
import ErgoProtocol
import Fluent
import Foundation
import Logging
import Synchronization
import Vapor

/// Which accounts are Adon's own (`ERGO_VERBOSE_ACCOUNTS`), and so the only ones whose activity is logged. Everyone else's
/// is silent while it works, and a problem is a `warning` or an `error` that says only a short pseudonym of the account.
/// See the README's Logs section.
///
/// This works through the `Logger` itself, which every service and job already takes. `logger(for:from:)` gives the
/// account's logger:
/// - **Verbose:** the base logger, with `account` set to the real id. `info` and below are logged.
/// - **Anyone else:** raised to `warning`, with `who` set to a pseudonym. So any `info` line written with this logger is
///   verbose-only without asking, and any `warning` or `error` is tied to the account without naming it.
///
/// `AccountAuthenticator` makes `request.logger` that logger, and anything that outlives the request (a detached run, an
/// analysis) calls `logger(for:from:)` with the application's logger. Never log an email, a token, a title or what someone
/// wrote, even to a verbose account: counts and sizes instead.
final class VerboseAccounts: Sendable {
	/// On a verbose account's logger: the real id
	static let accountKey = "account"

	/// On everyone else's: `pseudonym(for:)`
	static let pseudonymKey = "who"

	private let emails: Set<String>
	private let ids: Set<UUID>

	/// Accounts whose email matched when they signed in, so work with only an id knows them too. An email can be attached
	/// after launch, so this isn't worked out once.
	private let matched = Mutex<Set<UUID>>([])

	/// Entries are emails, compared case-insensitively like `AccountEmail` stores them, or account ids. An account signed
	/// in with Apple alone has no email on the server, so it can only be found by its id. Anything else is ignored.
	init(_ entries: [String]) {
		var emails = Set<String>()
		var ids = Set<UUID>()
		for entry in entries {
			let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
			if let id = UUID(uuidString: trimmed) {
				ids.insert(id)
			} else if let email = try? AccountEmail.normalized(trimmed) {
				emails.insert(email)
			}
		}
		self.emails = emails
		self.ids = ids
	}

	var isEmpty: Bool {
		emails.isEmpty && ids.isEmpty
	}

	// MARK: - Deciding

	func isVerbose(_ id: UUID) -> Bool {
		ids.contains(id) || matched.withLock { $0.contains(id) }
	}

	/// Whether this account is one of the configured ones, by its id or its email. Called wherever an account is loaded
	/// anyway, so no log line asks the database.
	@discardableResult
	func resolve(_ account: Account) -> Bool {
		guard let id = account.id else { return false }
		guard let email = account.email else { return isVerbose(id) }
		return resolve(email: email, of: id)
	}

	/// The same, for an email that was just attached to the account
	@discardableResult
	func resolve(email: String, of id: UUID) -> Bool {
		if emails.contains(email.lowercased()) {
			matched.withLock { _ = $0.insert(id) }
		}
		return isVerbose(id)
	}

	/// For an account that is known to be one of them without a row at hand
	func remember(_ id: UUID) {
		matched.withLock { _ = $0.insert(id) }
	}

	// MARK: - Loggers

	/// What to log with for work this account causes. `base` is the application's or request's logger: any account it was
	/// made for is replaced, never added to, so one account's id can't end up on another's line.
	func logger(for account: UUID, from base: Logger) -> Logger {
		var logger = base
		logger[metadataKey: Self.accountKey] = nil
		logger[metadataKey: Self.pseudonymKey] = nil

		if isVerbose(account) {
			logger[metadataKey: Self.accountKey] = .string("\(account)")
		} else {
			logger[metadataKey: Self.pseudonymKey] = .string(Self.pseudonym(for: account))
			logger.logLevel = max(logger.logLevel, .warning)
		}
		return logger
	}

	/// The first 8 hex characters of the id's SHA-256: stable, so a run of warnings can be read as one account's, and not
	/// reversible to the id
	static func pseudonym(for account: UUID) -> String {
		SHA256.hash(data: Data(account.uuidString.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
	}
}

// MARK: - Logger

extension Logger {
	/// Whether this is a verbose account's logger. Any other logger, including one that was never made for an account,
	/// is not, so `verbose` on it logs nothing.
	var isVerbose: Bool {
		self[metadataKey: VerboseAccounts.accountKey] != nil
	}

	/// For what happens as normal: logged at `info` for a verbose account and never for anyone else, whatever level the
	/// logger is at
	func verbose(
		_ message: @autoclosure () -> Logger.Message,
		metadata: @autoclosure () -> Logger.Metadata? = nil,
		file: String = #fileID,
		function: String = #function,
		line: UInt = #line
	) {
		guard isVerbose else { return }
		info(message(), metadata: metadata(), file: file, function: function, line: line)
	}

	/// What a log line may say about an error. A verbose account gets all of it, but Fluent's and the database's errors
	/// can quote the values of a query, which are other people's words, so anyone else's is only its type.
	func reason(for error: any Error) -> String {
		isVerbose ? String(reflecting: error) : String(describing: type(of: error))
	}
}

// MARK: - Request

extension Request {
	/// Called by `AccountAuthenticator` once the account is loaded. From here `logger` is the account's, and the account's
	/// email has been checked against the configured ones.
	func identify(_ account: Account) {
		guard let id = account.id else { return }
		ergo.verbose.resolve(account)
		logger = ergo.verbose.logger(for: id, from: logger)
	}

	/// For when sign-in changes which account this request is about: a merge, whose survivor may be verbose when the account
	/// the request came in as was not. The survivor may not have signed in since launch, so with accounts configured its
	/// row is read, once, to check its email.
	func identify(_ id: UUID) async {
		let verbose = ergo.verbose
		if !verbose.isEmpty, !verbose.isVerbose(id), let account = try? await Account.find(id, on: quietDB) {
			verbose.resolve(account)
		}
		logger = verbose.logger(for: id, from: logger)
	}

	/// Once someone has an email, which may be one of the configured ones
	func identify(attaching email: String, to id: UUID) {
		ergo.verbose.resolve(email: email, of: id)
		logger = ergo.verbose.logger(for: id, from: logger)
	}

	/// The logger for work that outlives this request, made from the application's, which has no request in its metadata
	func jobLogger(for account: UUID) -> Logger {
		ergo.verbose.logger(for: account, from: application.logger)
	}
}

// MARK: - Sockets

extension WebSocket {
	/// Says how long a verbose account's socket lived and how it ended. The opening is the request's own line.
	func logClosing(_ name: String, logger: Logger) {
		guard logger.isVerbose else { return }
		let opened = ContinuousClock.now
		onClose.whenComplete { [self] _ in
			let code = closeCode.map { "\($0)" } ?? "none"
			logger.verbose("\(name) socket closed", metadata: ["duration": "\(opened.duration(to: .now))", "code": "\(code)"])
		}
	}
}
