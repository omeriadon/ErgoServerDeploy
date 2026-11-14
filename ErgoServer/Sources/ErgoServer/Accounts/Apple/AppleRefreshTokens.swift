//
//  AppleRefreshTokens.swift
//  ErgoServer
//
//  Created by Adon Omeri on 10/11/2026.
//

import AsyncHTTPClient
import Crypto
import Foundation
import Vapor

/// What Apple gave for a sign-in's authorization code
struct AppleGrant: Sendable {
	let refreshToken: Secret

	/// The Apple ID's `sub` from the id token that came with it, so a code that belongs to another sign-in is noticed
	let subject: String?
}

/// Trading a sign-in's code for a refresh token and revoking it, which is how an account deletion takes the Sign in with
/// Apple connection away (App Store guideline 5.1.1(v)). A struct of closures like `PushSender`, so tests swap it.
struct AppleRefreshTokens: Sendable {
	/// False when there's no key, and then nothing is traded or revoked
	let isEnabled: Bool

	/// Throws when Apple refuses. What it throws never holds the code.
	let exchange: @Sendable (String) async throws -> AppleGrant
	let revoke: @Sendable (Secret) async throws -> Void

	static let disabled = AppleRefreshTokens(isEnabled: false) { _ in
		throw AppleAuthClient.Refusal(description: "disabled")
	} revoke: { _ in
		throw AppleAuthClient.Refusal(description: "disabled")
	}

	static func live(config: ServerConfig) -> AppleRefreshTokens {
		guard let signIn = config.appleSignIn else {
			return .disabled
		}
		let client = AppleAuthClient(config: signIn, clientID: config.appleApplicationID)
		return AppleRefreshTokens(isEnabled: true) { code in
			try await client.exchange(code: code)
		} revoke: { token in
			try await client.revoke(refreshToken: token)
		}
	}

	/// What a log line may say about a failure: Apple's reason or the error's type, never a code or a token
	static func describe(_ error: any Error) -> String {
		(error as? AppleAuthClient.Refusal)?.description ?? String(describing: type(of: error))
	}
}

/// Talks to `appleid.apple.com`, signing with the Sign in with Apple key like `APNSClient` and `DeviceCheckClient` sign
/// with theirs.
struct AppleAuthClient: Sendable {
	struct Refusal: Error, CustomStringConvertible {
		let description: String
	}

	static let host = "https://appleid.apple.com/auth"
	static let audience = "https://appleid.apple.com"

	/// Apple allows up to six months, but a secret is only needed for the call it goes with
	static let secretLifetime: TimeInterval = 5 * 60

	let config: ServerConfig.AppleSignIn

	/// The app's bundle id, which is also the audience of its identity tokens
	let clientID: String

	// MARK: - Calls

	func exchange(code: String, now: Date = .now) async throws -> AppleGrant {
		struct Reply: Decodable {
			let refreshToken: String?
			let idToken: String?

			enum CodingKeys: String, CodingKey {
				case refreshToken = "refresh_token"
				case idToken = "id_token"
			}
		}

		let reply = try await post("token", [
			("grant_type", "authorization_code"),
			("code", code),
			("client_id", clientID),
			("client_secret", Self.clientSecret(config: config, clientID: clientID, now: now)),
		])
		guard let decoded = try? JSONDecoder().decode(Reply.self, from: reply), let refreshToken = decoded.refreshToken, !refreshToken.isEmpty else {
			throw Refusal(description: "no refresh token in the reply")
		}
		return AppleGrant(refreshToken: Secret(refreshToken), subject: decoded.idToken.flatMap(Self.subject(of:)))
	}

	func revoke(refreshToken: Secret, now: Date = .now) async throws {
		_ = try await post("revoke", [
			("token", refreshToken.value),
			("token_type_hint", "refresh_token"),
			("client_id", clientID),
			("client_secret", Self.clientSecret(config: config, clientID: clientID, now: now)),
		])
	}

	/// Whatever goes wrong comes out as a `Refusal` that says only Apple's `error` or a status
	private func post(_ path: String, _ fields: [(String, String)]) async throws -> Data {
		do {
			var request = HTTPClientRequest(url: "\(Self.host)/\(path)")
			request.method = .POST
			request.headers.add(name: "Content-Type", value: "application/x-www-form-urlencoded")
			request.body = .bytes(ByteBuffer(string: Self.form(fields)))

			let response = try await AsyncHTTPClient.HTTPClient.shared.execute(request, timeout: .seconds(15))
			let collected = try await response.body.collect(upTo: 64 * 1024)
			let body = Data(collected.readableBytesView)
			guard response.status == .ok else {
				struct Failure: Decodable {
					let error: String
				}

				let reason = (try? JSONDecoder().decode(Failure.self, from: body))?.error
				throw Refusal(description: reason ?? "status \(response.status.code)")
			}
			return body
		} catch let error as Refusal {
			throw error
		} catch {
			throw Refusal(description: String(describing: type(of: error)))
		}
	}

	// MARK: - Encoding

	/// The client secret: a JWT the team's key signs, saying the app is asking
	static func clientSecret(config: ServerConfig.AppleSignIn, clientID: String, now: Date) throws -> String {
		struct Claims: Encodable {
			let iss: String
			let iat: Int
			let exp: Int
			let aud: String
			let sub: String
		}

		let key = try P256.Signing.PrivateKey(pemRepresentation: config.key)
		let issued = Int(now.timeIntervalSince1970)
		let claims = Claims(iss: config.teamID, iat: issued, exp: issued + Int(secretLifetime), aud: audience, sub: clientID)
		return try APNSClient.signedToken(key: key, keyID: config.keyID, claims: claims)
	}

	/// `application/x-www-form-urlencoded`, which `+` and `&` in a value would break if left as they are
	static func form(_ fields: [(String, String)]) -> String {
		fields.map { "\(escaped($0.0))=\(escaped($0.1))" }.joined(separator: "&")
	}

	private static let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

	private static func escaped(_ value: String) -> String {
		value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
	}

	/// The `sub` of a JWT that came straight from Apple over TLS, so its signature isn't checked again
	static func subject(of idToken: String) -> String? {
		struct Claims: Decodable {
			let sub: String
		}

		let parts = idToken.split(separator: ".")
		guard parts.count == 3 else { return nil }
		var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
		base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
		return Data(base64Encoded: base64).flatMap { try? JSONDecoder().decode(Claims.self, from: $0).sub }
	}
}
