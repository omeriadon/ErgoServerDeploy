//
//  DetachedRunsTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 8/11/2026.
//

import ErgoProtocol
import Foundation
import Synchronization
import Testing

struct DetachedRunsTests {
	/// Work that says `messages`, then waits until `open` is called, then says `last`
	final class Gated: Sendable {
		private let isOpen = Mutex(false)
		let started = Mutex(0)

		func open() {
			isOpen.withLock { $0 = true }
		}

		func work(saying messages: [String], then last: String? = nil) -> DetachedRuns.Work {
			{ emit in
				self.started.withLock { $0 += 1 }
				for message in messages {
					emit(message)
				}
				while !self.isOpen.withLock({ $0 }), !Task.isCancelled {
					try? await Task.sleep(for: .milliseconds(5))
				}
				if !Task.isCancelled, let last {
					emit(last)
				}
			}
		}
	}

	static func collect(_ stream: AsyncStream<String>) async -> [String] {
		var heard: [String] = []
		for await message in stream {
			heard.append(message)
		}
		return heard
	}

	@Test func aRunSaysEverythingThenEnds() async throws {
		let runs = DetachedRuns()
		let stream = try runs.start(run: UUID(), account: UUID()) { emit in
			emit("a")
			emit("b")
		}
		#expect(await Self.collect(stream) == ["a", "b"])
	}

	@Test func someoneArrivingLateHearsItFromTheStart() async throws {
		let runs = DetachedRuns()
		let account = UUID()
		let run = UUID()
		let first = try runs.start(run: run, account: account) { emit in
			emit("a")
			emit("b")
		}
		_ = await Self.collect(first)

		let late = try #require(runs.join(run: run, account: account))
		#expect(await Self.collect(late) == ["a", "b"])
	}

	@Test func aListenerGoingAwayDoesNotStopTheRun() async throws {
		let runs = DetachedRuns()
		let account = UUID()
		let run = UUID()
		let gated = Gated()

		let listening = Task {
			let stream = try runs.start(run: run, account: account, work: gated.work(saying: ["a"], then: "z"))
			for await _ in stream {
				// The connection drops after the first thing it hears
				return
			}
		}
		_ = try await listening.value

		// The app comes back
		let again = try #require(runs.join(run: run, account: account))
		gated.open()
		#expect(await Self.collect(again) == ["a", "z"])
	}

	@Test func startingTheSameRunAgainJoinsItAndDoesNotRunItTwice() async throws {
		let runs = DetachedRuns()
		let account = UUID()
		let run = UUID()
		let gated = Gated()

		let first = try runs.start(run: run, account: account, work: gated.work(saying: ["a"], then: "z"))
		let second = try runs.start(run: run, account: account, work: gated.work(saying: ["other"]))
		gated.open()

		#expect(await Self.collect(first) == ["a", "z"])
		#expect(await Self.collect(second) == ["a", "z"])
		#expect(gated.started.withLock { $0 } == 1)
	}

	@Test func anotherAccountHasNeitherTheRunNorItsId() async throws {
		let runs = DetachedRuns()
		let run = UUID()
		let owner = UUID()
		let other = UUID()
		_ = try await Self.collect(runs.start(run: run, account: owner) { $0("mine") })

		#expect(runs.join(run: run, account: other) == nil)

		// Its own run with the same id is a different run
		let theirs = try runs.start(run: run, account: other) { $0("theirs") }
		#expect(await Self.collect(theirs) == ["theirs"])
		#expect(try await Self.collect(#require(runs.join(run: run, account: owner))) == ["mine"])
	}

	@Test func cancellingStopsTheWorkAndKeepsWhatItSaid() async throws {
		let runs = DetachedRuns()
		let account = UUID()
		let run = UUID()
		let gated = Gated()

		let stream = try runs.start(run: run, account: account, work: gated.work(saying: ["a"], then: "never"))
		#expect(runs.cancel(run: run, account: account))
		#expect(await Self.collect(stream) == ["a"])
		#expect(!runs.cancel(run: run, account: account))
		#expect(try await Self.collect(#require(runs.join(run: run, account: account))) == ["a"])
	}

	@Test func anotherAccountCannotCancel() async throws {
		let runs = DetachedRuns()
		let run = UUID()
		let account = UUID()
		let gated = Gated()

		let stream = try runs.start(run: run, account: account, work: gated.work(saying: [], then: "z"))
		#expect(!runs.cancel(run: run, account: UUID()))
		gated.open()
		#expect(await Self.collect(stream) == ["z"])
	}

	@Test func aFinishedRunIsForgottenAfterTheRetention() async throws {
		let clock = Mutex(Date(timeIntervalSince1970: 1_000_000))
		let runs = DetachedRuns(retention: 60) { clock.withLock { $0 } }
		let account = UUID()
		let run = UUID()
		_ = try await Self.collect(runs.start(run: run, account: account) { $0("a") })

		clock.withLock { $0 += 59 }
		#expect(runs.join(run: run, account: account) != nil)

		clock.withLock { $0 += 2 }
		#expect(runs.join(run: run, account: account) == nil)
		#expect(runs.count == 0)
	}

	@Test func aRunThatIsStillGoingIsNeverForgotten() async throws {
		let clock = Mutex(Date(timeIntervalSince1970: 1_000_000))
		let runs = DetachedRuns(retention: 60) { clock.withLock { $0 } }
		let account = UUID()
		let run = UUID()
		let gated = Gated()
		let stream = try runs.start(run: run, account: account, work: gated.work(saying: ["a"]))

		clock.withLock { $0 += 10000 }
		#expect(runs.join(run: run, account: account) != nil)
		gated.open()
		_ = await Self.collect(stream)
	}

	@Test func anAccountCannotRunTooManyAtOnce() async throws {
		let runs = DetachedRuns(perAccount: 2)
		let account = UUID()
		let gated = Gated()
		let first = try runs.start(run: UUID(), account: account, work: gated.work(saying: []))
		let second = try runs.start(run: UUID(), account: account, work: gated.work(saying: []))

		#expect(throws: ServiceError.self) {
			try runs.start(run: UUID(), account: account, work: gated.work(saying: []))
		}
		// Someone else's runs don't count
		let other = try runs.start(run: UUID(), account: UUID(), work: gated.work(saying: []))

		gated.open()
		_ = await Self.collect(first)
		_ = await Self.collect(second)
		_ = await Self.collect(other)

		// Finished runs make room
		_ = try runs.start(run: UUID(), account: account) { _ in }
	}

	@Test func shuttingDownStopsEveryRunAndRefusesNewOnes() async throws {
		let runs = DetachedRuns()
		let account = UUID()
		let gated = Gated()
		let stream = try runs.start(run: UUID(), account: account, work: gated.work(saying: ["a"], then: "never"))

		await runs.shutDown()
		#expect(await Self.collect(stream) == ["a"])
		#expect(throws: ServiceError.self) {
			try runs.start(run: UUID(), account: account) { _ in }
		}
	}
}
