//
//  DeviceCheckClient.swift
//  ErgoServer
//
//  Created by Adon Omeri on 10/11/2026.
//

import AsyncHTTPClient
import Crypto
import ErgoProtocol
import Foundation
import Logging
import Vapor

/// Apple's DeviceCheck: two bits it keeps for each device, which survive reinstalling the app. Bit 0 says the device has
/// given its free allowance to an account, and Apple also says which month the bits were last set.
///
/// Only the production host is used, like pushes: a build run from Xcode makes development tokens, which Apple refuses here.
struct DeviceCheckClient: Sendable {
	enum Outcome: Sendable {
		case granted

		/// Another account took this device's allowance this month
		case claimedThisMonth
	}

	static let host = "https://api.devicecheck.apple.com/v1"
	static let maxTokenCharacters = 8192

	let config: ServerConfig.DeviceCheck

	private struct Query: Encodable {
		let device_token: String
		let transaction_id: String
		let timestamp: Int
	}

	private struct Update: Encodable {
		let device_token: String
		let transaction_id: String
		let timestamp: Int
		let bit0: Bool
		let bit1: Bool
	}

	private struct Bits: Decodable {
		let bit0: Bool
		let last_update_time: String?
	}

	private static let refused = ServiceError(code: .providerUnavailable, message: "Couldn't check this device with Apple, try again later")

	/// The token is never logged
	func claim(deviceToken: String, logger: Logger, now: Date = .now) async throws -> Outcome {
		guard !deviceToken.isEmpty, deviceToken.count <= Self.maxTokenCharacters else {
			throw ServiceError(code: .invalidRequest, message: "Expected a DeviceCheck token")
		}
		let timestamp = Int(now.timeIntervalSince1970 * 1000)

		let query = Query(device_token: deviceToken, transaction_id: UUID().uuidString, timestamp: timestamp)
		let found = try await post("query_two_bits", JSONEncoder().encode(query), logger: logger, now: now)
		// Apple answers a device it has never heard of with a sentence, not JSON
		let bits = try? JSONDecoder().decode(Bits.self, from: found)
		if let bits, bits.bit0, bits.last_update_time == UsagePeriod.month(of: now) {
			return .claimedThisMonth
		}

		let update = Update(device_token: deviceToken, transaction_id: UUID().uuidString, timestamp: timestamp, bit0: true, bit1: false)
		_ = try await post("update_two_bits", JSONEncoder().encode(update), logger: logger, now: now)
		return .granted
	}

	private func post(_ path: String, _ body: Data, logger: Logger, now: Date) async throws -> Data {
		do {
			let key = try P256.Signing.PrivateKey(pemRepresentation: config.key)
			let bearer = try APNSClient.signedToken(key: key, keyID: config.keyID, teamID: config.teamID, now: now)

			var request = HTTPClientRequest(url: "\(Self.host)/\(path)")
			request.method = .POST
			request.headers.add(name: "Authorization", value: "Bearer \(bearer)")
			request.headers.add(name: "Content-Type", value: "application/json")
			request.body = .bytes(ByteBuffer(bytes: body))

			let response = try await AsyncHTTPClient.HTTPClient.shared.execute(request, timeout: .seconds(15))
			let collected = try await response.body.collect(upTo: 64 * 1024)
			guard response.status == .ok else {
				logger.warning("DeviceCheck refused a call", metadata: ["path": "\(path)", "status": "\(response.status.code)"])
				throw Self.refused
			}
			return Data(collected.readableBytesView)
		} catch let error as ServiceError {
			throw error
		} catch {
			logger.warning("Couldn't reach DeviceCheck", metadata: ["path": "\(path)", "error": "\(String(describing: type(of: error)))"])
			throw Self.refused
		}
	}
}
