//
//  APNSClient.swift
//  ErgoServer
//
//  Created by Adon Omeri on 7/11/2026.
//

import Crypto
import ErgoProtocol
import Foundation
import Synchronization
import Vapor

/// Talks to Apple with no dependency beyond swift-crypto and the application's client, which negotiates the HTTP/2
/// Apple requires. Signs an ES256 JWT with the APNs key and reuses it for 40 minutes: Apple refuses a token older than an
/// hour, or one renewed more often than every 20 minutes.
final class APNSClient: Sendable {
	static let tokenLifetime: TimeInterval = 40 * 60

	private let config: ServerConfig.APNS
	private let client: @Sendable () -> (any Client)?
	private let cached = Mutex<(token: String, made: Date)?>(nil)

	/// Throws when the key doesn't read, here rather than at the first push
	init(config: ServerConfig.APNS, client: @escaping @Sendable () -> (any Client)?) throws {
		_ = try P256.Signing.PrivateKey(pemRepresentation: config.key)
		self.config = config
		self.client = client
	}

	// MARK: - Sending

	/// Never throws: a push that can't be sent mustn't fail what caused it. What it returns never holds the token.
	func send(_ message: PushMessage) async -> PushOutcome {
		guard let client = client() else {
			return .failed("no client")
		}
		do {
			var headers = HTTPHeaders()
			try headers.add(name: .authorization, value: "bearer \(bearer())")
			headers.add(name: "apns-topic", value: config.topic)
			headers.add(name: "apns-push-type", value: message.alert == nil ? "background" : "alert")
			headers.add(name: "apns-priority", value: message.alert == nil ? "5" : "10")
			headers.add(name: "apns-collapse-id", value: message.board)

			let request = try ClientRequest(
				method: .POST,
				url: URI(string: "https://api.push.apple.com/3/device/\(message.deviceToken)"),
				headers: headers,
				body: ByteBuffer(bytes: Self.payload(for: message)),
				timeout: .seconds(15)
			)

			// The client's debug log can print the URL, and the URL has the device's token in it
			var quiet = Logger(label: "ergo.apns")
			quiet.logLevel = .info
			let response = try await client.logging(to: quiet).send(request)
			return outcome(of: response)
		} catch {
			return .failed(String(describing: type(of: error)))
		}
	}

	private func outcome(of response: ClientResponse) -> PushOutcome {
		if response.status == .ok {
			return .sent
		}

		struct Reply: Decodable {
			let reason: String
		}

		let reason = response.body.flatMap { body in
			try? JSONDecoder().decode(Reply.self, from: Data(body.readableBytesView)).reason
		}
		if response.status == .gone || reason == "BadDeviceToken" || reason == "Unregistered" {
			return .deviceGone
		}
		if reason == "ExpiredProviderToken" {
			cached.withLock { $0 = nil }
		}
		return .failed(reason ?? "status \(response.status.code)")
	}

	// MARK: - Payload

	/// `{ "aps": { "alert": { "title", "body" }, "sound", "thread-id", "content-available": 1 }, "board" }`, and for a
	/// silent push only `content-available` in `aps`.
	static func payload(for message: PushMessage) throws -> Data {
		let aps = PushPayload.Aps(alert: message.alert, sound: message.alert == nil ? nil : "default", threadID: message.alert == nil ? nil : message.board)
		return try JSONEncoder().encode(PushPayload(aps: aps, board: message.board))
	}

	// MARK: - Token

	private func bearer(now: Date = .now) throws -> String {
		if let token = cached.withLock({ cached in
			cached.flatMap { now.timeIntervalSince($0.made) < Self.tokenLifetime ? $0.token : nil }
		}) {
			return token
		}
		let key = try P256.Signing.PrivateKey(pemRepresentation: config.key)
		let token = try Self.signedToken(key: key, keyID: config.keyID, teamID: config.teamID, now: now)
		cached.withLock { $0 = (token, now) }
		return token
	}

	/// `<header>.<claims>.<signature>`, each base64url, the signature raw rather than DER as JWTs need
	static func signedToken(key: P256.Signing.PrivateKey, keyID: String, teamID: String, now: Date) throws -> String {
		struct Claims: Encodable {
			let iss: String
			let iat: Int
		}

		return try signedToken(key: key, keyID: keyID, claims: Claims(iss: teamID, iat: Int(now.timeIntervalSince1970)))
	}

	/// The same ES256 token with other claims, which is what Apple's other services take: DeviceCheck and the Sign in with
	/// Apple client secret both sign like this
	static func signedToken(key: P256.Signing.PrivateKey, keyID: String, claims: some Encodable) throws -> String {
		let header = try base64URL(JSONEncoder().encode(TokenHeader(alg: "ES256", kid: keyID)))
		let payload = try base64URL(JSONEncoder().encode(claims))
		let signed = "\(header).\(payload)"
		let signature = try key.signature(for: Data(signed.utf8))
		return "\(signed).\(base64URL(signature.rawRepresentation))"
	}

	/// Outside `signedToken`, since the Swift the server is built with can't nest a type in a generic function
	private struct TokenHeader: Encodable {
		let alg: String
		let kid: String
	}

	private static func base64URL(_ data: Data) -> String {
		data.base64EncodedString()
			.replacingOccurrences(of: "+", with: "-")
			.replacingOccurrences(of: "/", with: "_")
			.replacingOccurrences(of: "=", with: "")
	}
}

private struct PushPayload: Encodable {
	struct Aps: Encodable {
		var alert: PushMessage.Alert?
		var sound: String?
		var threadID: String?
		var contentAvailable = 1

		enum CodingKeys: String, CodingKey {
			case alert, sound
			case threadID = "thread-id"
			case contentAvailable = "content-available"
		}
	}

	let aps: Aps
	let board: String
}
