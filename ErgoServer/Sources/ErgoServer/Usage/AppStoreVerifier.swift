//
//  AppStoreVerifier.swift
//  ErgoServer
//
//  Created by Adon Omeri on 10/11/2026.
//

import ErgoProtocol
import Foundation
import JWT

/// What Apple signs for a purchase: StoreKit's `jwsRepresentation`. Only the fields the plan needs.
struct AppStoreTransaction: JWTPayload {
	let bundleId: String
	let productId: String
	let originalTransactionId: String

	/// Milliseconds since 1970, like every date Apple puts in one
	let expiresDate: Double?

	/// Set when Apple refunded it
	let revocationDate: Double?

	func verify(using _: some JWTAlgorithm) async throws {}
}

/// Checks a transaction was signed by the App Store, through the certificate chain in its header, up to Apple's root.
/// A transaction from Xcode's own StoreKit testing is signed by something else, so it never passes.
struct AppStoreVerifier: Sendable {
	private let verifier: X5CVerifier
	private let bundleID: String

	/// `rootCertificate` is Apple Root CA G3 in PEM
	init(rootCertificate: String, bundleID: String) throws {
		verifier = try X5CVerifier(rootCertificates: [rootCertificate])
		self.bundleID = bundleID
	}

	func verified(_ jws: String) async throws -> AppStoreTransaction {
		let transaction: AppStoreTransaction
		do {
			transaction = try await verifier.verifyJWS(jws, as: AppStoreTransaction.self)
		} catch {
			throw ServiceError(code: .invalidRequest, message: "Expected a purchase signed by the App Store")
		}
		guard transaction.bundleId == bundleID else {
			throw ServiceError(code: .invalidRequest, message: "Expected a purchase made in Ergo")
		}
		guard PlanProducts.all.contains(transaction.productId) else {
			throw ServiceError(code: .invalidRequest, message: "Expected a purchase of Ergo Plus, found '\(transaction.productId)'")
		}
		return transaction
	}
}
