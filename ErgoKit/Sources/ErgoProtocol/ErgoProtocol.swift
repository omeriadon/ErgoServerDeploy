//
//  ErgoProtocol.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import Foundation

/// How the app and the Ergo server talk.
///
/// REST sends `versionHeader` on every request, and `Authorization: Bearer <token>` on all but `Path.accounts` and
/// `Path.invitePreview`. Errors come back as a non-2xx status with a `ServiceError` body.
///
/// The server answers every version from its minimum up to its own. Below that is `outdatedApp`, and an app that's
/// answered but getting old finds `updateHeader` on its replies. See `Plans/13-Versions.md`.
///
/// The translate socket gets exactly one `TranslateClientMessage.translate`, answers with any number of `.event`s,
/// then exactly one `.finished` or `.failed`, and closes. Sending `.cancel` or closing stops the work.
/// `TranslateRequest.scope` picks the answer's type: `.statement` gets `TranslateServerMessage`s, `.argument` gets
/// `BreakDownServerMessage`s. Failures before the scope is known, like a missing request, use the first.
///
/// The ask socket gets exactly one `AskClientMessage.ask`, answers with any number of `.text`, `.tool` and `.action`
/// messages, then exactly one `.finished` or `.failed`, and closes. Sending `.cancel` or closing stops the work.
/// A message type this version doesn't know decodes to `.unknown`, so adding one needs no new protocol version.
///
/// The device login socket sends `.code` once, then `.connected` or `.failed`, and closes. Closing it cancels the login.
///
/// Sync needs an account signed in with Apple or an email and password. The sync socket only ever sends `SyncLiveMessage`s and stays open
/// until either end closes it; the server pings it every 20 s.
///
/// A shared board's records are copied by the server into every member's account, so a member hears about them through
/// their own sync and socket, with their own cursor. Who's on a board arrives the same way, as `share` records only the
/// server writes. A push to a board the account may not edit doesn't fail the request: it comes back in
/// `SyncResponse.rejected`. Invite tokens go in bodies, never in API paths, so they can't land in logs.
public enum ErgoProtocol {
	/// What this build speaks. Only a change an older app would misread bumps it: a new field, path or message kind doesn't.
	public static let version = 1

	/// The oldest protocol the server's code can still answer. Only the server reads it, and its `ERGO_MINIMUM_PROTOCOL`
	/// can ask for a newer one. Raising it drops the code that served the versions below.
	public static let minimumVersion = 1

	public static let versionHeader = "Ergo-Protocol-Version"

	/// On every reply to an app the server still answers but would like updated, holding `AppUpdate.recommended`
	public static let updateHeader = "Ergo-App-Update"

	public enum Path {
		/// POST → `AccountCreated`, no auth
		public static let accounts = "v1/accounts"

		/// DELETE
		public static let account = "v1/account"

		/// POST `SignInWithAppleRequest` → `SignedIn`
		public static let appleSignIn = "v1/account/apple"

		/// DELETE signs out this device only
		public static let accountToken = "v1/account/token"

		/// POST `EmailCredentials` → 204. Attaches an email and password to this device's account.
		public static let register = "v1/account/register"

		/// POST `EmailCredentials` → `SignedIn`. Joins the account that owns the email.
		public static let logIn = "v1/account/login"

		/// POST `ChangePasswordRequest` → 204. Signs out every other device.
		public static let password = "v1/account/password"

		/// GET → `[ConnectionStatus]`. PUT `ConnectionUpload` → `ConnectionStatus`, or DELETE, at `v1/connections/<provider>`.
		public static let connections = "v1/connections"

		/// WebSocket of `DeviceLoginMessage`
		public static let deviceLogin = "v1/connections/codex/device-login"

		/// WebSocket of `TranslateClientMessage` and `TranslateServerMessage` (or `BreakDownServerMessage`)
		public static let translate = "v1/translate"

		/// WebSocket of `AskClientMessage` and `AskServerMessage`. Needs a signed-in account.
		public static let ask = "v1/ask"

		/// POST of one MCP JSON-RPC message, from the CLI answering an ask. `<token>` is the run's, there's no other auth.
		public static let askTools = "v1/ask/tools"

		/// GET → `UsageStatus`
		public static let usage = "v1/usage"

		/// POST `PlanUpload` → `UsageStatus`
		public static let plan = "v1/account/plan"

		/// POST `DeviceClaimUpload` → `UsageStatus`
		public static let deviceClaim = "v1/account/device-claim"

		/// POST `SyncRequest` → `SyncResponse`
		public static let sync = "v1/sync"

		/// WebSocket of `SyncLiveMessage`
		public static let syncLive = "v1/sync/live"

		/// POST `BoardAnalysisRequest` → 202, signed in. The run carries on without the request, and its results arrive as
		/// `annotation` and `analysis` sync records. DELETE → 204 stops it, keeping what's been written.
		public static func boardAnalysis(_ board: String) -> String {
			"v1/boards/\(board)/analysis"
		}
	}

	// MARK: - Coding

	/// Dates are ISO 8601 on both ends, so always code with these
	public static var encoder: JSONEncoder {
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		return encoder
	}

	public static var decoder: JSONDecoder {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		return decoder
	}
}
