//
//  Secret.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoProtocol
import Foundation
import Synchronization

/// A user's token, key or `auth.json`, unsealed. Prints as redacted everywhere, so it can't end up in a log by accident.
struct Secret: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
	/// Only for handing to a CLI or sealing again
	let value: String

	init(_ value: String) {
		self.value = value
	}

	var description: String {
		"<redacted>"
	}

	var debugDescription: String {
		description
	}

	var customMirror: Mirror {
		Mirror(self, children: [])
	}
}

/// One stored connection, unsealed for a call
struct ProviderCredential: Sendable, Hashable {
	let provider: Provider
	let kind: CredentialKind
	let secret: Secret
}

/// Codex rotates its refresh token as it uses it, so each call has to start from whatever the last one left behind
final class LatestSecret: Sendable {
	private let value: Mutex<Secret>

	init(_ secret: Secret) {
		value = Mutex(secret)
	}

	var current: Secret {
		value.withLock { $0 }
	}

	func replace(with secret: Secret) {
		value.withLock { $0 = secret }
	}
}
