//
//  BoardAnalysisJobs.swift
//  ErgoServer
//
//  Created by Adon Omeri on 8/11/2026.
//

import ErgoProtocol
import Foundation
import Synchronization
import Vapor

/// The board analyses running right now, which outlive the request that started them. One per board and a few per
/// account, and all of them are cancelled when the server shuts down.
///
/// In memory, so a restart loses them: the board's `analysis` record says `running` until `staleAfter` passes, and
/// then the app shows it as interrupted.
final class BoardAnalysisJobs: LifecycleHandler, Sendable {
	static let perAccount = 3

	private struct Job {
		let account: UUID
		let run: UUID
		var task: Task<Void, Never>?

		/// Stopped before its task was made
		var isStopped = false
	}

	private struct State {
		var jobs: [String: Job] = [:]
		var isShuttingDown = false
	}

	private let state = Mutex<State>(State())

	/// Throws `.busy` when the board already has a run, or the account has too many. A job holds its place until `release`.
	func reserve(board: String, account: UUID, run: UUID) throws {
		try state.withLock { state in
			guard !state.isShuttingDown else {
				throw ServiceError(code: .busy, message: "Expected a server that isn't shutting down, try again in a moment")
			}
			guard state.jobs[board] == nil else {
				throw ServiceError(code: .busy, message: "Expected one analysis at a time on a board, another one is still running")
			}
			let running = state.jobs.values.filter { $0.account == account }.count
			guard running < Self.perAccount else {
				throw ServiceError(code: .busy, message: "Expected at most \(Self.perAccount) analyses at once, found \(running) running")
			}
			state.jobs[board] = Job(account: account, run: run)
		}
	}

	/// The task, once it's made. If the run was stopped in between, it's stopped now.
	func attach(_ task: Task<Void, Never>, board: String, run: UUID) {
		let stopped = state.withLock { state -> Bool in
			guard state.jobs[board]?.run == run else { return true }
			state.jobs[board]?.task = task
			return state.jobs[board]?.isStopped == true
		}
		if stopped {
			task.cancel()
		}
	}

	func release(board: String, run: UUID) {
		state.withLock { state in
			if state.jobs[board]?.run == run {
				state.jobs[board] = nil
			}
		}
	}

	/// Stops the board's run, keeping what it has written. Nil `account` is the server itself. Returns whether there was one.
	@discardableResult
	func stop(board: String, by account: UUID?) throws -> Bool {
		let (found, task) = try state.withLock { state -> (Bool, Task<Void, Never>?) in
			guard let job = state.jobs[board] else { return (false, nil) }
			if let account, job.account != account {
				throw ServiceError(code: .invalidRequest, message: "Expected an analysis you started, found one someone else started")
			}
			state.jobs[board]?.isStopped = true
			return (true, job.task)
		}
		task?.cancel()
		return found
	}

	/// Whether the server is going down, in which case a cancelled run writes nothing: its database is going too
	var isShuttingDown: Bool {
		state.withLock { $0.isShuttingDown }
	}

	// MARK: - Lifecycle

	func shutdownAsync(_: Application) async {
		let tasks = state.withLock { state -> [Task<Void, Never>] in
			state.isShuttingDown = true
			return state.jobs.values.compactMap(\.task)
		}
		for task in tasks {
			task.cancel()
		}
		for task in tasks {
			await task.value
		}
	}
}
