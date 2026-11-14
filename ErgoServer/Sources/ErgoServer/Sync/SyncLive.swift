//
//  SyncLive.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoProtocol
import Foundation
import NIOCore
import Synchronization
import Vapor

/// `WS v1/sync/live`: tells an account's other devices that one of them pushed, so they sync now instead of polling.
///
/// In memory, so it only reaches sockets on this server. More than one instance would need something like
/// Redis pub/sub between them.
final class SyncLive: Sendable {
	private struct Listener: Sendable {
		let token: UUID
		let socket: WebSocket
	}

	/// Account → socket id → listener
	private let listeners = Mutex<[UUID: [UUID: Listener]]>([:])

	/// Only on the socket's event loop, straight after the upgrade, so a push just after can't be missed
	func listen(_ socket: WebSocket, account: UUID, token: UUID, pingInterval: Duration) {
		let id = UUID()
		listeners.withLock { $0[account, default: [:]][id] = Listener(token: token, socket: socket) }

		// Proxies drop a quiet connection, and this one is quiet until someone pushes
		socket.pingInterval = TimeAmount(pingInterval)
		socket.onClose.whenComplete { [weak self] _ in
			self?.listeners.withLock { listeners in
				listeners[account]?[id] = nil
				if listeners[account]?.isEmpty == true {
					listeners[account] = nil
				}
			}
		}
	}

	/// Every socket of the account but the pushing token's
	func changed(account: UUID, cursor: Int, except token: UUID?) {
		let others = sockets(of: account) { $0.token != token }
		guard !others.isEmpty, let data = try? ErgoProtocol.encoder.encode(SyncLiveMessage.changed(cursor: cursor)) else { return }

		let text = String(decoding: data, as: UTF8.self)
		for socket in others {
			socket.send(text, promise: nil)
		}
	}

	/// After signing out, so a signed-out device stops hearing about the account
	func close(token: UUID, account: UUID) {
		for socket in sockets(of: account, where: { $0.token == token }) {
			socket.close(code: .normalClosure, promise: nil)
		}
	}

	/// After deleting the account
	func close(account: UUID) {
		for socket in sockets(of: account, where: { _ in true }) {
			socket.close(code: .normalClosure, promise: nil)
		}
	}

	/// Whether this device has a socket open, so it's already been told and needs no push
	func isListening(token: UUID) -> Bool {
		listeners.withLock { listeners in
			listeners.values.contains { sockets in
				sockets.values.contains { $0.token == token }
			}
		}
	}

	func count(of account: UUID) -> Int {
		listeners.withLock { $0[account]?.count ?? 0 }
	}

	private func sockets(of account: UUID, where include: (Listener) -> Bool) -> [WebSocket] {
		listeners.withLock { listeners in
			(listeners[account] ?? [:]).values.filter(include).map(\.socket)
		}
	}
}
