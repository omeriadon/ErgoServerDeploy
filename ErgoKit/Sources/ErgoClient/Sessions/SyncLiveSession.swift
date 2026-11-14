//
//  SyncLiveSession.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoProtocol
import Foundation
#if canImport(FoundationNetworking)
	import FoundationNetworking
#endif

public extension ErgoClient {
	/// Tells this device when another one pushed. It never finishes on its own: it throws when the connection drops,
	/// and the caller reconnects. Cancelling the consuming task closes it.
	func syncLive() -> AsyncThrowingStream<SyncLiveMessage, Error> {
		messages(at: ErgoProtocol.Path.syncLive) { _ in false }
	}
}
