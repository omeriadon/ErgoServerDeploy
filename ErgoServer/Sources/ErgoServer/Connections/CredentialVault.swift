//
//  CredentialVault.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import Crypto
import ErgoProtocol
import Foundation

/// Seals credentials and synced records at rest with AES-GCM. The account and provider, or the account and record,
/// are the associated data, so a sealed blob only opens in the row it was written for.
struct CredentialVault: Sendable, CustomStringConvertible {
	struct Unreadable: Error, CustomStringConvertible {
		var description: String {
			"Couldn't unseal a stored credential or record"
		}
	}

	private let key: SymmetricKey

	init(key: SymmetricKey) {
		self.key = key
	}

	var description: String {
		"CredentialVault(<redacted>)"
	}

	func seal(_ secret: Secret, account: UUID, provider: Provider) throws -> Data {
		try seal(Data(secret.value.utf8), as: Self.associatedData(account, provider))
	}

	func open(_ sealed: Data, account: UUID, provider: Provider) throws -> Secret {
		try Secret(String(decoding: open(sealed, as: Self.associatedData(account, provider)), as: UTF8.self))
	}

	private static func associatedData(_ account: UUID, _ provider: Provider) -> Data {
		Data("\(account)/\(provider.rawValue)".utf8)
	}

	// MARK: - Sync records

	func seal(_ fields: [String: SyncField], account: UUID, record: SyncRecord.Key) throws -> Data {
		try seal(JSONEncoder().encode(fields), as: Self.associatedData(account, record))
	}

	func open(_ sealed: Data, account: UUID, record: SyncRecord.Key) throws -> [String: SyncField] {
		let data = try open(sealed, as: Self.associatedData(account, record))
		do {
			return try JSONDecoder().decode([String: SyncField].self, from: data)
		} catch {
			throw Unreadable()
		}
	}

	private static func associatedData(_ account: UUID, _ record: SyncRecord.Key) -> Data {
		Data("\(account)/sync/\(record.kind.rawValue)/\(record.id)".utf8)
	}

	// MARK: - Board titles

	func seal(title: String, board: UUID) throws -> Data {
		try seal(Data(title.utf8), as: Data("board/\(board)/title".utf8))
	}

	func openTitle(_ sealed: Data, board: UUID) throws -> String {
		try String(decoding: open(sealed, as: Data("board/\(board)/title".utf8)), as: UTF8.self)
	}

	// MARK: - Apple refresh tokens

	func seal(appleRefreshToken: Secret, account: UUID) throws -> Data {
		try seal(Data(appleRefreshToken.value.utf8), as: Data("\(account)/apple/refresh".utf8))
	}

	func openAppleRefreshToken(_ sealed: Data, account: UUID) throws -> Secret {
		try Secret(String(decoding: open(sealed, as: Data("\(account)/apple/refresh".utf8)), as: UTF8.self))
	}

	// MARK: - Sealing

	private func seal(_ data: Data, as associatedData: Data) throws -> Data {
		let box = try AES.GCM.seal(data, using: key, authenticating: associatedData)
		guard let combined = box.combined else {
			throw Unreadable()
		}
		return combined
	}

	private func open(_ sealed: Data, as associatedData: Data) throws -> Data {
		do {
			let box = try AES.GCM.SealedBox(combined: sealed)
			return try AES.GCM.open(box, using: key, authenticating: associatedData)
		} catch {
			throw Unreadable()
		}
	}
}
