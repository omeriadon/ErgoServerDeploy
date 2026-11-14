//
//  SyncLiveTests.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoClient
import ErgoProtocol
@testable import ErgoServer
import Fluent
import Foundation
import Synchronization
import Testing
import VaporTesting

/// Through a real server on a free port and the app's own `ErgoClient` and `SyncReplica`
struct SyncLiveTests {
	/// A new install signed in with `subject`
	func device(_ server: URL, _ subject: String = "apple-user") async throws -> (ErgoClient, SignedIn) {
		let account = try await ErgoClient(server: server, token: nil).createAccount()
		let client = ErgoClient(server: server, token: account.token)
		let nonce = UUID().uuidString
		let signedIn = try await client.signInWithApple(identityToken: FakeApple.token(subject: subject, nonce: nonce), nonce: nonce)
		return (client, signedIn)
	}

	final class Heard: Sendable {
		private let messages = Mutex<[SyncLiveMessage]>([])
		private let ended = Mutex(false)

		var all: [SyncLiveMessage] {
			messages.withLock { $0 }
		}

		var hasEnded: Bool {
			ended.withLock { $0 }
		}

		func listen(_ client: ErgoClient) -> Task<Void, Never> {
			Task {
				do {
					for try await message in client.syncLive() {
						messages.withLock { $0.append(message) }
					}
				} catch {}
				ended.withLock { $0 = true }
			}
		}
	}

	// MARK: - Live

	@Test func tellsTheOtherDevicesOnly() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withLiveServer(.testing(scratch)) { app, server in
			let (phone, account) = try await device(server)
			let (pad, _) = try await device(server)
			let (other, someoneElse) = try await device(server, "someone-else")

			let heard = (phone: Heard(), pad: Heard(), other: Heard())
			let listening = [heard.phone.listen(phone), heard.pad.listen(pad), heard.other.listen(other)]
			defer { listening.forEach { $0.cancel() } }
			#expect(try await eventually {
				app.ergo.live.count(of: account.accountID) == 2 && app.ergo.live.count(of: someoneElse.accountID) == 1
			})

			// Nothing changed, nobody hears
			_ = try await phone.sync(SyncRequest(cursor: nil, changes: []))

			let board = newBoardID()
			_ = try await phone.sync(SyncRequest(cursor: nil, changes: [
				statementChange(board, ["content": SyncField(value: content("From the phone"), stamp: stamp(device: "phone"))]),
			]))
			#expect(try await eventually { heard.pad.all == [.changed(cursor: 1)] })

			_ = try await pad.sync(SyncRequest(cursor: 1, changes: [
				statementChange(board, ["position": SyncField(value: ["x": 1, "y": 2], stamp: stamp(device: "pad"))]),
			]))
			#expect(try await eventually { heard.phone.all == [.changed(cursor: 2)] })

			// The phone's first message is the pad's push, so it never heard its own
			#expect(heard.phone.all == [.changed(cursor: 2)])
			#expect(heard.pad.all == [.changed(cursor: 1)])
			#expect(heard.other.all == [])

			// Signing out closes that device's socket
			try await pad.signOut()
			#expect(try await eventually { heard.pad.hasEnded && app.ergo.live.count(of: account.accountID) == 1 })
		}
	}

	@Test func anonymousAccountsCantListen() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withLiveServer(.testing(scratch)) { app, server in
			let account = try await ErgoClient(server: server, token: nil).createAccount()
			let client = ErgoClient(server: server, token: account.token)

			await #expect(throws: ServiceError(code: .signInRequired, message: "Sign in to sync")) {
				for try await _ in client.syncLive() {}
			}
			await #expect(throws: ServiceError(code: .signInRequired, message: "Sign in to sync")) {
				try await client.sync(SyncRequest(cursor: nil, changes: []))
			}
			#expect(app.ergo.live.count(of: account.id) == 0)
		}
	}

	@Test func bigBodiesAreRefusedOnTheWire() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withLiveServer(.testing(scratch)) { app, server in
			let (client, _) = try await device(server)
			let changes = (0 ..< 5).map { _ in
				statementChange(newBoardID(), ["content": SyncField(value: content(String(repeating: "a", count: 250 * 1024)), stamp: stamp())])
			}

			do {
				_ = try await client.sync(SyncRequest(cursor: nil, changes: changes))
				Issue.record("Expected the sync to be refused")
			} catch let error as ServiceError {
				#expect(error.code == .tooLarge)
			}
			#expect(try await SyncRecordRow.query(on: app.db).count() == 0)
		}
	}

	// MARK: - Replicas

	struct Device {
		var replica: SyncReplica
		let client: ErgoClient
		var superseded: [SupersededField] = []

		init(_ name: String, client: ErgoClient) {
			replica = SyncReplica(device: name)
			self.client = client
		}

		/// One round trip, as the app makes them
		mutating func syncOnce() async throws -> SyncApplied {
			let request = replica.makeRequest()
			let response = try await client.sync(request)
			let applied = replica.apply(response, sent: request)
			superseded += applied.superseded
			return applied
		}

		mutating func syncUntilDone() async throws {
			for _ in 0 ..< 50 {
				if try await !syncOnce().syncAgain {
					return
				}
			}
			Issue.record("Expected sync to settle within 50 round trips")
		}
	}

	@Test(arguments: [1, 2, 3] as [UInt64])
	func replicasConverge(seed: UInt64) async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }
		var config = ServerConfig.testing(scratch)
		config.syncsPerMinute = 100_000

		try await withLiveServer(config) { app, server in
			let (phoneClient, account) = try await device(server)
			let (padClient, _) = try await device(server)
			var devices = [Device("phone", client: phoneClient), Device("pad", client: padClient)]

			var random = SplitMix(seed: seed)
			let newLinkID = newBoardID()
			let boards = (0 ..< 3).map { _ in newBoardID() }
			let statements = (0 ..< 3).map { _ in newBoardID() }
			let scratchpads = (0 ..< 2).map { _ in newBoardID() }
			let bookmarks = ["fallacy.strawman", "razor.occam"]

			for step in 0 ..< 60 {
				let index = Int.random(in: 0 ..< devices.count, using: &random)
				let board = boards.randomElement(using: &random) ?? boards[0]
				let statement = statements.randomElement(using: &random) ?? statements[0]
				switch Int.random(in: 0 ..< 10, using: &random) {
					case 0:
						let fields = ["board": JSONValue.string(board), "content": content("Step \(step) on \(index)")]
						devices[index].replica.recordLocal(kind: .statement, id: statement, fields: fields)
					case 1:
						let position: JSONValue = ["x": .number(Double(step)), "y": .number(Double(index))]
						devices[index].replica.recordLocal(kind: .statement, id: statement, fields: ["board": .string(board), "position": position])
					case 2:
						let scratchpad = scratchpads.randomElement(using: &random) ?? scratchpads[0]
						let slot = Int.random(in: 0 ..< SyncFieldName.descriptorSlots, using: &random)
						devices[index].replica.recordLocal(kind: .scratchpad, id: scratchpad, fields: [SyncFieldName.descriptor(slot): .string("claim \(step)")])
					case 3:
						devices[index].replica.recordLocal(kind: .board, id: board, fields: ["deleted": .bool(Bool.random(using: &random))])
					case 4:
						let bookmark = bookmarks.randomElement(using: &random) ?? bookmarks[0]
						devices[index].replica.recordLocal(kind: .bookmark, id: bookmark, fields: ["present": .bool(Bool.random(using: &random))])
					case 5:
						devices[index].replica.recordLocal(kind: .setting, id: "ditherEnabled", fields: ["value": .bool(Bool.random(using: &random))])
					case 6:
						_ = try await devices[index].syncOnce()
					case 7:
						let fields = ["board": JSONValue.string(board), "premise": .string(statements[0]), "conclusion": .string(statements[1])]
						devices[index].replica.recordLocal(kind: .link, id: newLinkID, fields: fields)
					default:
						try await devices[index].syncUntilDone()
				}
			}

			for _ in 0 ..< 2 {
				for index in devices.indices {
					try await devices[index].syncUntilDone()
				}
			}

			#expect(devices[0].replica.pending.isEmpty)
			#expect(devices[1].replica.pending.isEmpty)
			#expect(devices[0].replica.records == devices[1].replica.records)

			// And the server holds the same, sealed
			let rows = try await SyncRecordRow.query(on: app.db).filter(\.$account.$id == account.accountID).all()
			let stored = try Dictionary(uniqueKeysWithValues: rows.map { row in try (row.key, row.record(app.ergo.vault)) })
			#expect(stored == devices[0].replica.records)
			#expect(stored.count > 3)
		}
	}

	@Test func concurrentEditsMakeOneCopy() async throws {
		let scratch = try Scratch()
		defer { scratch.remove() }

		try await withLiveServer(.testing(scratch)) { _, server in
			let (phoneClient, _) = try await device(server)
			let (padClient, _) = try await device(server)
			var phone = Device("phone", client: phoneClient)
			var pad = Device("pad", client: padClient)
			let statement = newBoardID()

			phone.replica.recordLocal(kind: .statement, id: statement, fields: ["content": content("First")])
			try await phone.syncUntilDone()
			try await pad.syncUntilDone()

			// Both offline, both typing
			phone.replica.recordLocal(kind: .statement, id: statement, fields: ["content": content("Phone's version")])
			pad.replica.recordLocal(kind: .statement, id: statement, fields: ["content": content("Pad's version")])
			try await phone.syncUntilDone()
			try await pad.syncUntilDone()
			try await phone.syncUntilDone()

			#expect(phone.replica.records == pad.replica.records)
			#expect(phone.superseded.count + pad.superseded.count == 1)
			#expect(phone.superseded.allSatisfy { $0.kind == .statement } && pad.superseded.allSatisfy { $0.kind == .statement })
			let kept = phone.replica[.statement, statement]?.fields["content"]?.value
			let lost = (phone.superseded + pad.superseded).first?.lost.value
			#expect(Set([kept, lost]) == Set([content("Phone's version"), content("Pad's version")]))
		}
	}
}

/// SplitMix64, so a failing seed fails the same way every run
struct SplitMix: RandomNumberGenerator {
	var state: UInt64

	init(seed: UInt64) {
		state = seed
	}

	mutating func next() -> UInt64 {
		state &+= 0x9E37_79B9_7F4A_7C15
		var z = state
		z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
		z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
		return z ^ (z >> 31)
	}
}
