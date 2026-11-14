//
//  DetachedRuns.swift
//  ErgoKit
//
//  Created by Adon Omeri on 8/11/2026.
//

import Foundation
import Synchronization

/// Work that carries on without the connection that started it, so a force quit app finds the answer when it comes
/// back. Ask and Break Down use it.
///
/// A run is the server's work for one request id, kept under the account that started it. It buffers everything it
/// says, as the encoded messages the socket would send, so whoever connects, now or later, hears it from the start.
/// Starting a run that already exists for the account joins it and ignores the new work, so a client that doesn't know
/// whether its request arrived can send it again. A finished run is kept for `retention` and then forgotten, and a
/// restart forgets them all, so a client that asks for one the server no longer has just starts it again.
///
/// Only `cancel` stops a run. A listener going away never does.
public final class DetachedRuns: Sendable {
	/// Says one more thing. Messages come out in the order they went in.
	public typealias Emit = @Sendable (String) -> Void

	/// What a run does. It says everything through `emit`, including how it ended, and returns when it's over.
	public typealias Work = @Sendable (_ emit: @escaping Emit) async -> Void

	public static let defaultRetention: TimeInterval = 60 * 60
	public static let defaultPerAccount = 3

	private struct Key: Hashable {
		let account: UUID
		let run: UUID
	}

	private struct Entry {
		var messages: [String] = []
		var listeners: [UUID: AsyncStream<String>.Continuation] = [:]
		var task: Task<Void, Never>?
		var finished: Date?

		var isFinished: Bool {
			finished != nil
		}
	}

	private struct State {
		var entries: [Key: Entry] = [:]
		var isShuttingDown = false
	}

	private let state = Mutex<State>(State())
	private let retention: TimeInterval
	private let perAccount: Int
	private let now: @Sendable () -> Date

	public init(
		retention: TimeInterval = DetachedRuns.defaultRetention,
		perAccount: Int = DetachedRuns.defaultPerAccount,
		now: @escaping @Sendable () -> Date = { .now }
	) {
		self.retention = retention
		self.perAccount = perAccount
		self.now = now
	}

	// MARK: - Starting

	/// Starts `work` for `run`, or joins it if the account already has that run. Everything the run has said comes out of
	/// the stream first, then what it says from now, and the stream ends when the run does. Throws `.busy` when the
	/// account has too many running, or the server is going down.
	public func start(run: UUID, account: UUID, work: @escaping Work) throws -> AsyncStream<String> {
		let key = Key(account: account, run: run)
		return try state.withLock { state in
			Self.forgetExpired(&state, at: now(), retention: retention)
			if let joined = listen(to: key, in: &state) {
				return joined
			}
			guard !state.isShuttingDown else {
				throw ServiceError(code: .busy, message: "Expected a server that isn't shutting down, try again in a moment")
			}
			let running = state.entries.filter { $0.key.account == account && !$0.value.isFinished }.count
			guard running < perAccount else {
				throw ServiceError(code: .busy, message: "Expected at most \(perAccount) things running at once, found \(running)")
			}

			state.entries[key] = Entry()
			let stream = listen(to: key, in: &state) ?? AsyncStream { $0.finish() }
			state.entries[key]?.task = Task { [self] in
				await work { message in self.say(message, to: key) }
				end(key)
			}
			return stream
		}
	}

	/// Joins a run the account already has, or nil when the server has no such run, which is also what another account's is
	public func join(run: UUID, account: UUID) -> AsyncStream<String>? {
		let key = Key(account: account, run: run)
		return state.withLock { state in
			Self.forgetExpired(&state, at: now(), retention: retention)
			return listen(to: key, in: &state)
		}
	}

	// MARK: - Stopping

	/// Stops the run, which keeps what it has said. Returns whether the account had one still going.
	@discardableResult
	public func cancel(run: UUID, account: UUID) -> Bool {
		let task = state.withLock { state -> Task<Void, Never>? in
			guard let entry = state.entries[Key(account: account, run: run)], !entry.isFinished else { return nil }
			return entry.task
		}
		task?.cancel()
		return task != nil
	}

	/// Stops every run and waits for them, for when the server shuts down
	public func shutDown() async {
		let tasks = state.withLock { state -> [Task<Void, Never>] in
			state.isShuttingDown = true
			return state.entries.values.compactMap(\.task)
		}
		for task in tasks {
			task.cancel()
		}
		for task in tasks {
			await task.value
		}
	}

	/// How many runs the server still has, finished or not
	public var count: Int {
		state.withLock { state in
			Self.forgetExpired(&state, at: now(), retention: retention)
			return state.entries.count
		}
	}

	// MARK: - Inside

	/// A stream of what the run has said, then what it says next. A run that's over ends the stream after its messages.
	private func listen(to key: Key, in state: inout State) -> AsyncStream<String>? {
		guard let entry = state.entries[key] else { return nil }
		let (stream, continuation) = AsyncStream.makeStream(of: String.self)
		for message in entry.messages {
			continuation.yield(message)
		}
		if entry.isFinished {
			continuation.finish()
		} else {
			let id = UUID()
			continuation.onTermination = { [weak self] _ in
				self?.state.withLock { $0.entries[key]?.listeners[id] = nil }
			}
			state.entries[key]?.listeners[id] = continuation
		}
		return stream
	}

	private func say(_ message: String, to key: Key) {
		state.withLock { state in
			guard let entry = state.entries[key] else { return }
			state.entries[key]?.messages.append(message)
			for listener in entry.listeners.values {
				listener.yield(message)
			}
		}
	}

	private func end(_ key: Key) {
		let listeners = state.withLock { state -> [AsyncStream<String>.Continuation] in
			guard let entry = state.entries[key] else { return [] }
			state.entries[key]?.finished = now()
			state.entries[key]?.listeners = [:]
			return Array(entry.listeners.values)
		}
		// Not under the lock, since finishing runs a listener's `onTermination`, which takes it
		for listener in listeners {
			listener.finish()
		}
	}

	private static func forgetExpired(_ state: inout State, at now: Date, retention: TimeInterval) {
		state.entries = state.entries.filter { _, entry in
			guard let finished = entry.finished else { return true }
			return now.timeIntervalSince(finished) <= retention
		}
	}
}
