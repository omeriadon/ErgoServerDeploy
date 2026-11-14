//
//  DeviceLoginSession.swift
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
	/// Codex's device login, run by the server: a code to enter, then the new connection.
	/// Cancelling the consuming task cancels the login.
	func codexDeviceLogin() -> AsyncThrowingStream<DeviceLoginMessage, Error> {
		messages(at: ErgoProtocol.Path.deviceLogin) { message in
			switch message {
				case .code:
					false
				case .connected, .failed:
					true
			}
		}
	}
}
