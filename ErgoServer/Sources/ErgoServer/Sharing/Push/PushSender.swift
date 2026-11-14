//
//  PushSender.swift
//  ErgoServer
//
//  Created by Adon Omeri on 7/11/2026.
//

import Foundation
import Logging
import Vapor

/// One notification for one device
struct PushMessage: Sendable, Hashable {
	struct Alert: Encodable, Sendable, Hashable {
		let title: String
		let body: String
	}

	/// The APNs device token, never logged
	let deviceToken: String
	let board: String

	/// Nil for a silent push
	let alert: Alert?
}

enum PushOutcome: Sendable, Equatable {
	case sent

	/// Apple says this token is dead, so its row goes
	case deviceGone

	/// Worth a log line and nothing else. Holds only Apple's reason or a status, never the token or the title.
	case failed(String)
}

/// How a message reaches Apple, a struct of closures like `AppleTokenVerifier`, so tests swap it
struct PushSender: Sendable {
	/// False skips the work of finding devices
	let isEnabled: Bool
	let send: @Sendable (PushMessage) async -> PushOutcome

	static let disabled = PushSender(isEnabled: false) { _ in .failed("disabled") }

	/// `client` is called for each send, since the application's client isn't ready, and shouldn't be started, in `configure`
	static func live(config: ServerConfig, client: @escaping @Sendable () -> (any Client)?, logger: Logger) -> PushSender {
		guard let apns = config.apns else {
			return .disabled
		}
		do {
			let apnsClient = try APNSClient(config: apns, client: client)
			return PushSender(isEnabled: true) { message in
				await apnsClient.send(message)
			}
		} catch {
			// `ServerConfig.load` already refused a key that doesn't read, so only a hand-made config gets here
			logger.error("Couldn't read the APNs key, so no pushes will be sent")
			return .disabled
		}
	}
}
