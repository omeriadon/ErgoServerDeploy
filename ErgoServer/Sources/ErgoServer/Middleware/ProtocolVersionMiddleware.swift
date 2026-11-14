//
//  ProtocolVersionMiddleware.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoProtocol
import Vapor

/// The protocols this server answers. Every version from `minimum` to `current` is served, so the app in people's hands
/// keeps working while a newer one is in review. See `Plans/13-Versions.md`.
struct ProtocolVersions: Sendable, Equatable {
	/// The oldest that's answered. `ERGO_MINIMUM_PROTOCOL` raises it once nearly everyone has updated.
	var minimum = ErgoProtocol.minimumVersion

	/// The oldest that isn't told to update. `ERGO_RECOMMENDED_PROTOCOL` raises it once the newer app is out, never
	/// before, or people are told to get an update that isn't there.
	var recommended = ErgoProtocol.minimumVersion

	var current = ErgoProtocol.version

	enum Check: Equatable {
		/// Answered as `version`, and told to update if it's getting old
		case served(version: Int, update: Bool)

		/// No header, one that isn't a number, or below `minimum`
		case tooOld

		/// An app ahead of this server, which only happens when a server is rolled back. Not the app's fault, so it's
		/// never told to update.
		case tooNew(Int)
	}

	func check(_ header: String?) -> Check {
		guard let version = header.flatMap(Int.init), version >= minimum else {
			return .tooOld
		}
		guard version <= current else {
			return .tooNew(version)
		}
		return .served(version: version, update: version < recommended)
	}
}

/// Turns away any app too old to be answered, before it can misread a reply, and tells the ones getting old to update.
/// Apple's notifications, the CLIs' tool calls and the two public pages for invite links are the exceptions, since none
/// comes from the app and none has heard of the header.
struct ProtocolVersionMiddleware: AsyncMiddleware {
	func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
		guard !AppleNotificationController.isNotification(request),
		      !AskToolController.isToolCall(request),
		      !JoinController.isPublic(request)
		else {
			return try await next.respond(to: request)
		}

		let versions = request.ergo.config.protocols
		switch versions.check(request.headers.first(name: ErgoProtocol.versionHeader)) {
			case .tooOld:
				throw ServiceError(code: .outdatedApp, message: "Expected Ergo with protocol \(versions.minimum) or later, update the app")

			case let .tooNew(version):
				// Only a server rolled back below the app in people's hands does this, which is worth knowing once a minute
				if let leftOut = request.ergo.logThrottle.allow("An app is ahead of this server") {
					request.logger.warning("An app is ahead of this server", metadata: ["app": "\(version)", "server": "\(versions.current)", "leftOut": "\(leftOut)"])
				}
				throw ServiceError(code: .providerUnavailable, message: "Expected a server with protocol \(version), found \(versions.current)")

			case let .served(version, update):
				request.protocolVersion = version
				let response = try await next.respond(to: request)
				if update {
					response.headers.replaceOrAdd(name: ErgoProtocol.updateHeader, value: AppUpdate.recommended.rawValue)
				}
				return response
		}
	}
}

extension Request {
	private struct ProtocolVersionKey: StorageKey {
		typealias Value = Int
	}

	/// The protocol the app asking speaks, for a route that answers an older one differently. The server's own for a
	/// request that isn't from the app.
	var protocolVersion: Int {
		get {
			storage[ProtocolVersionKey.self] ?? ErgoProtocol.version
		}
		set {
			storage[ProtocolVersionKey.self] = newValue
		}
	}
}
