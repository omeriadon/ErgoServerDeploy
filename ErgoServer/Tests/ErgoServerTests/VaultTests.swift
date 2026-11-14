//
//  VaultTests.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import Crypto
import ErgoProtocol
@testable import ErgoServer
import Foundation
import Testing

struct VaultTests {
	let vault = CredentialVault(key: SymmetricKey(size: .bits256))
	let account = UUID()
	let secret = Secret("sk-ant-oat-secret")

	@Test func roundTrips() throws {
		let sealed = try vault.seal(secret, account: account, provider: .claude)
		#expect(try vault.open(sealed, account: account, provider: .claude) == secret)
		#expect(!String(decoding: sealed, as: UTF8.self).contains(secret.value))
	}

	@Test func tamperedCiphertextFails() throws {
		var sealed = try vault.seal(secret, account: account, provider: .claude)
		sealed[sealed.count / 2] ^= 0x01

		#expect(throws: CredentialVault.Unreadable.self) {
			try vault.open(sealed, account: account, provider: .claude)
		}
	}

	@Test func otherRowsCantOpenIt() throws {
		let sealed = try vault.seal(secret, account: account, provider: .claude)

		#expect(throws: CredentialVault.Unreadable.self) {
			try vault.open(sealed, account: UUID(), provider: .claude)
		}
		#expect(throws: CredentialVault.Unreadable.self) {
			try vault.open(sealed, account: account, provider: .codex)
		}
	}

	@Test func otherKeysCantOpenIt() throws {
		let sealed = try vault.seal(secret, account: account, provider: .claude)

		#expect(throws: CredentialVault.Unreadable.self) {
			try CredentialVault(key: SymmetricKey(size: .bits256)).open(sealed, account: account, provider: .claude)
		}
	}

	@Test func secretsPrintRedacted() {
		let credential = ProviderCredential(provider: .claude, kind: .subscription, secret: secret)

		for text in ["\(secret)", String(reflecting: secret), "\(credential)", String(reflecting: credential), "\(vault)"] {
			#expect(!text.contains(secret.value))
		}
	}
}
