//
//  DetachedRunsShutdown.swift
//  ErgoServer
//
//  Created by Adon Omeri on 8/11/2026.
//

import ErgoProtocol
import Vapor

/// Stops every ask and breakdown when the server shuts down, so no CLI is left running
struct DetachedRunsShutdown: LifecycleHandler {
	let runs: DetachedRuns

	init(_ runs: DetachedRuns) {
		self.runs = runs
	}

	func shutdownAsync(_: Application) async {
		await runs.shutDown()
	}
}
