//
//  ProcessRunner.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import Foundation
import Subprocess
import Synchronization
#if canImport(System)
	import System
#else
	import SystemPackage
#endif

/// Runs the provider CLIs: a few at a time, each with exactly the environment it's given,
/// and killed (SIGTERM, then SIGKILL two seconds later) when the caller is cancelled or the call takes too long
final class ProcessRunner: Sendable {
	struct Command: Sendable, Hashable {
		var executable: String
		var arguments: [String]
		var environment: [String: String]
		var directory: URL

		/// The prompt goes here, never in `arguments`
		var input = ""
	}

	struct Finished: Sendable {
		let status: TerminationStatus
		let output: Data

		/// The last few kilobytes, for the server log only, since it can hold anything
		let errorOutput: String
		let duration: Duration
	}

	/// Whoever a run directory belongs to while a CLI runs in it
	struct Owner: Sendable, Hashable {
		let user: UInt32
		let group: UInt32

		init(user: UInt32, group: UInt32) {
			self.user = user
			self.group = group
		}

		/// Nil when there's no such user
		init?(named name: String) {
			guard let entry = getpwnam(name) else { return nil }
			self.init(user: entry.pointee.pw_uid, group: entry.pointee.pw_gid)
		}
	}

	struct TimedOut: Error {}

	let prefix: [String]
	let owner: Owner?
	let timeout: Duration
	private let slots: ProcessSlots

	init(prefix: [String] = [], owner: Owner? = nil, maxProcesses: Int, timeout: Duration) {
		self.prefix = prefix
		self.owner = owner
		self.timeout = timeout
		slots = ProcessSlots(maxProcesses)
	}

	// MARK: - Running

	/// Waits for the process to exit and collects what it wrote. Throws `TimedOut`, or `CancellationError` once it's been killed.
	func run(_ command: Command, in directory: RunDirectory) async throws -> Finished {
		try await withSlot(in: directory) {
			let start = ContinuousClock.now
			let (executable, arguments) = self.launch(command)

			let finished = try await self.withTimeout(self.timeout) {
				let result = try await Subprocess.run(
					executable,
					arguments: arguments,
					environment: Self.environment(command.environment),
					workingDirectory: FilePath(command.directory.path),
					platformOptions: Self.options,
					input: .string(command.input),
					output: .bytes(limit: 16 << 20),
					error: .bytes(limit: 4 << 20)
				)
				return Finished(
					status: result.terminationStatus,
					output: Data(result.standardOutput),
					errorOutput: String(decoding: result.standardError.suffix(4096), as: UTF8.self),
					duration: start.duration(to: .now)
				)
			}

			// A killed process still returns normally, so its empty output mustn't look like an answer
			try Task.checkCancellation()
			return finished
		}
	}

	/// Hands each line of stdout and stderr to `lines` as it arrives, for CLIs that talk while they run
	func stream(
		_ command: Command,
		in directory: RunDirectory,
		timeout: Duration,
		lines: @escaping @Sendable (String) async -> Void
	) async throws -> TerminationStatus {
		try await withSlot(in: directory) {
			let (executable, arguments) = self.launch(command)

			let status = try await self.withTimeout(timeout) {
				try await Subprocess.run(
					executable,
					arguments: arguments,
					environment: Self.environment(command.environment),
					workingDirectory: FilePath(command.directory.path),
					platformOptions: Self.options,
					input: .string(command.input),
					output: .sequence,
					error: .combinedWithOutput
				) { execution in
					for try await line in execution.standardOutput.strings(bufferingPolicy: .maxLineLength(Self.lineLimit)) {
						await lines(line)
					}
				}.terminationStatus
			}

			try Task.checkCancellation()
			return status
		}
	}

	/// What to do after hearing a line from a CLI that's talked to as it runs
	struct Reply: Sendable {
		var send: [String] = []

		/// Closes its stdin, which is how it's told to exit
		var isDone = false
	}

	/// For a CLI that has to be answered as it goes: writes `opening`, hands each line of stdout to `lines`, and writes
	/// whatever comes back. Stderr is dropped, so it can't land in the middle of a line.
	func converse(
		_ command: Command,
		in directory: RunDirectory,
		timeout: Duration,
		opening: String,
		lines: @escaping @Sendable (String) async -> Reply
	) async throws -> TerminationStatus {
		try await withSlot(in: directory) {
			let (executable, arguments) = self.launch(command)

			let status = try await self.withTimeout(timeout) {
				try await Subprocess.run(
					executable,
					arguments: arguments,
					environment: Self.environment(command.environment),
					workingDirectory: FilePath(command.directory.path),
					platformOptions: Self.options,
					input: .inputWriter,
					output: .sequence,
					error: .discarded
				) { execution in
					let writer = execution.standardInputWriter
					_ = try await writer.write(opening + "\n", using: UTF8.self)

					for try await line in execution.standardOutput.strings(bufferingPolicy: .maxLineLength(Self.lineLimit)) {
						let reply = await lines(line)
						for message in reply.send {
							_ = try await writer.write(message + "\n", using: UTF8.self)
						}
						if reply.isDone {
							try await writer.finish()
						}
					}
				}.terminationStatus
			}

			try Task.checkCancellation()
			return status
		}
	}

	// MARK: - Helpers

	/// A tool's whole result can come back through the CLI as one line
	private static let lineLimit = 8 << 20

	private func withSlot<T>(in directory: RunDirectory, _ body: () async throws -> T) async throws -> T {
		try await slots.acquire()
		defer { slots.release() }

		// Registered before the handover, so one that fails partway still gives the directory back
		defer {
			if owner != nil {
				directory.takeBack()
			}
		}
		if let owner {
			try directory.handOver(to: owner)
		}

		return try await body()
	}

	private func withTimeout<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
		try await withThrowingTaskGroup(of: T?.self) { group in
			group.addTask { try await work() }
			group.addTask {
				try await Task.sleep(for: limit)
				return nil
			}
			defer { group.cancelAll() }

			guard let first = try await group.next(), let value = first else {
				throw TimedOut()
			}
			return value
		}
	}

	/// The prefix, if any, runs the CLI
	private func launch(_ command: Command) -> (Executable, Arguments) {
		var words = prefix + [command.executable] + command.arguments
		let first = words.removeFirst()
		let executable: Executable = first.contains("/") ? .path(FilePath(first)) : .name(first)
		return (executable, Arguments(words))
	}

	private static func environment(_ variables: [String: String]) -> Subprocess.Environment {
		.custom(Dictionary(uniqueKeysWithValues: variables.compactMap { key, value in
			Subprocess.Environment.Key(rawValue: key).map { ($0, value) }
		}))
	}

	/// Its own session, so the teardown reaches anything the CLI started too
	private static var options: PlatformOptions {
		var options = PlatformOptions()
		options.createSession = true
		options.teardownSequence = [.gracefulShutDown(toProcessGroup: true, allowedDurationToNextStep: .seconds(2))]
		return options
	}
}

// MARK: - ProcessSlots

/// A counting semaphore that gives up its place in line when the waiting task is cancelled
private final class ProcessSlots: Sendable {
	private struct State {
		var free: Int
		var waiting: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
	}

	private let state: Mutex<State>

	init(_ count: Int) {
		state = Mutex(State(free: count))
	}

	func acquire() async throws {
		let id = UUID()
		try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
				// Checked under the lock, so a cancel either lands before this or finds the waiter
				let granted: Bool? = state.withLock { state in
					if Task.isCancelled {
						return false
					}
					if state.free > 0 {
						state.free -= 1
						return true
					}
					state.waiting.append((id, continuation))
					return nil
				}
				switch granted {
					case true?: continuation.resume()
					case false?: continuation.resume(throwing: CancellationError())
					case nil: break
				}
			}
		} onCancel: {
			let waiter = state.withLock { state in
				state.waiting.firstIndex { $0.id == id }.map { state.waiting.remove(at: $0).continuation }
			}
			waiter?.resume(throwing: CancellationError())
		}
	}

	func release() {
		let next = state.withLock { state in
			if state.waiting.isEmpty {
				state.free += 1
				return CheckedContinuation<Void, Error>?.none
			}
			return state.waiting.removeFirst().continuation
		}
		next?.resume()
	}
}
