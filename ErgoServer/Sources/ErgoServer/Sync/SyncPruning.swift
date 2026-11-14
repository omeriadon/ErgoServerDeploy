//
//  SyncPruning.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import Foundation
import Synchronization
import Vapor

/// Prunes old tombstones once at launch and then every `interval`, so a server that restarts often still prunes
final class SyncPruning: LifecycleHandler {
	let interval: Duration
	private let loop = Mutex<Task<Void, Never>?>(nil)

	init(interval: Duration) {
		self.interval = interval
	}

	func didBootAsync(_ application: Application) async throws {
		let interval = interval
		let task = Task { [sync = application.ergo.sync, database = application.db, logger = application.logger] in
			while !Task.isCancelled {
				do {
					let pruned = try await sync.prune(on: database)
					// Nobody's account, so not for a verbose account to hear about, and it's as normal as a day passing
					logger.debug("Pruned tombstones", metadata: ["count": "\(pruned)"])
				} catch {
					logger.error("Pruning tombstones failed", metadata: ["error": "\(String(reflecting: error))"])
				}
				try? await Task.sleep(for: interval)
			}
		}
		loop.withLock { $0 = task }
	}

	func shutdownAsync(_: Application) async {
		let task = loop.withLock { $0.take() }
		task?.cancel()
		await task?.value
	}
}
