//
//  SyncConvergenceTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoSync
import Foundation
import Testing

/// Three devices and a server, doing random edits, deletes and syncs in random orders. Whatever happens,
/// once everyone has synced twice they must all hold the same records.
struct SyncConvergenceTests {
	static let keys: [SyncRecord.Key] = [
		SyncRecord.Key(kind: .scratchpad, id: "6F1C2E9A-3B4D-4E5F-8A9B-0C1D2E3F4A5B"),
		SyncRecord.Key(kind: .scratchpad, id: "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"),
		SyncRecord.Key(kind: .scratchpad, id: "11111111-2222-4333-8444-555555555555"),
		SyncRecord.Key(kind: .setting, id: SyncedSetting.logicLetters.rawValue),
		SyncRecord.Key(kind: .setting, id: SyncedSetting.ditherEnabled.rawValue),
		SyncRecord.Key(kind: .bookmark, id: "fallacy.ad-hominem"),
		SyncRecord.Key(kind: .statement, id: "AAAAAAAA-2222-4333-8444-555555555555"),
		SyncRecord.Key(kind: .statement, id: "BBBBBBBB-2222-4333-8444-555555555555"),
		SyncRecord.Key(kind: .link, id: "CCCCCCCC-2222-4333-8444-555555555555"),
	]

	/// What the random walk may do besides editing and syncing
	struct Hazards {
		var lostReplies = false
		var resets = false
		var pruning = false
	}

	struct World {
		var random: SeededRandom
		var server = FakeSyncServer()
		var devices: [FakeDevice]
		var edits = 0

		/// Every edit made after its device caught up, with the field it was made from
		var history: [(key: SyncRecord.Key, field: String, edit: SyncField, parent: SyncField?)] = []

		init(seed: UInt64, skew: Bool) {
			var random = SeededRandom(seed: seed)
			devices = ["A", "B", "C"].map { name in
				FakeDevice(name, skew: skew ? Int64.random(in: -240_000 ... 240_000, using: &random) : 0)
			}
			self.random = random
		}

		mutating func randomValue(for field: String) -> JSONValue {
			edits += 1
			switch field {
				case "deleted", "present":
					return .bool(.random(using: &random))
				case "content":
					// Mostly unique, sometimes the same text on two devices
					return Int.random(in: 0 ..< 5, using: &random) == 0 ? ["english": "same"] : ["english": .string("edit \(edits)")]
				default:
					return .string(["rain", "snow", "wind"].randomElement(using: &random)!)
			}
		}

		mutating func edit(_ index: Int) {
			let key = SyncConvergenceTests.keys.randomElement(using: &random)!
			let names = key.kind == .scratchpad
				? ["content", "created", "descriptor.0", "descriptor.1"]
				: key.kind.fieldNames.sorted()
			var fields: [String: JSONValue] = [:]
			for name in names.shuffled(using: &random).prefix(Int.random(in: 1 ... 2, using: &random)) {
				fields[name] = randomValue(for: name)
			}
			if key.kind == .scratchpad, Int.random(in: 0 ..< 6, using: &random) == 0 {
				fields = ["deleted": .bool(.random(using: &random))]
			}

			let wasCaughtUp = devices[index].replica.isCaughtUp
			let parents = fields.keys.map { (name: $0, field: devices[index].replica.records[key]?.fields[$0]) }
			guard devices[index].edit(key.kind, key.id, fields, server), wasCaughtUp else { return }
			for (name, parent) in parents {
				guard let field = devices[index].replica.records[key]?.fields[name], field != parent else { continue }
				history.append((key, name, field, parent))
			}
		}

		mutating func step(_ hazards: Hazards) {
			server.now += Int64.random(in: 1 ... 2000, using: &random)
			let index = Int.random(in: 0 ..< devices.count, using: &random)
			switch Int.random(in: 0 ..< 100, using: &random) {
				case 0 ..< 55:
					edit(index)
				case 55 ..< 95:
					if devices[index].inFlight != nil {
						let losing = hazards.lostReplies && Int.random(in: 0 ..< 8, using: &random) == 0
						_ = losing ? devices[index].loseReply() : devices[index].receive(server)
					} else {
						// Half the time the reply comes back later, after more edits here and elsewhere
						let limit = Bool.random(using: &random) ? Int.random(in: 1 ... 3, using: &random) : nil
						devices[index].send(to: &server, limit: limit)
						if Bool.random(using: &random) {
							_ = devices[index].receive(server)
						}
					}
				case 95 ..< 97 where hazards.resets:
					devices[index].replica.reset()
				case 97 ..< 99 where hazards.pruning:
					server.prune()
				default:
					server.now += Int64.random(in: 0 ... 60000, using: &random)
			}
		}

		mutating func settle() {
			for _ in 0 ..< 2 {
				for index in devices.indices {
					devices[index].syncUntilDone(with: &server)
				}
			}
		}
	}

	/// After pruning, a tombstone the server dropped can still be on a device. Deleted and gone look the same to the
	/// user, so only then are they compared as the same.
	/// Pruning also drops the statements and links of a pruned board, which a device keeps until it prunes too.
	/// They're ignored on every device, so they count as gone as well.
	static func expectConverged(_ world: World, seed: UInt64, ignoringTombstones: Bool = false) {
		for device in world.devices {
			func visible(_ records: [SyncRecord.Key: SyncRecord]) -> [SyncRecord.Key: SyncRecord] {
				ignoringTombstones ? records.filter { !$0.value.isDeleted && !device.replica.isIgnored($0.value) } : records
			}
			#expect(visible(device.replica.records) == visible(world.server.records), "Seed \(seed): \(device.replica.device) disagrees with the server")
			#expect(device.replica.pending.isEmpty, "Seed \(seed): \(device.replica.device) still has pending changes")
			#expect(device.replica.isCaughtUp, "Seed \(seed): \(device.replica.device) never caught up")
		}
	}

	// MARK: - Convergence

	@Test(arguments: 0 ..< 150 as Range<UInt64>)
	func replicasConverge(seed: UInt64) {
		var world = World(seed: seed, skew: true)
		for _ in 0 ..< 300 {
			world.step(Hazards())
		}
		world.settle()
		Self.expectConverged(world, seed: seed)
	}

	/// Lost replies, sign-outs and pruned tombstones on top
	@Test(arguments: 1000 ..< 1150 as Range<UInt64>)
	func replicasConvergeThroughHazards(seed: UInt64) {
		var world = World(seed: seed, skew: true)
		for _ in 0 ..< 300 {
			world.step(Hazards(lostReplies: true, resets: true, pruning: true))
		}
		world.settle()
		Self.expectConverged(world, seed: seed, ignoringTombstones: true)
	}

	// MARK: - Nothing lost

	/// With a reliable network, every value a device wrote is still somewhere: the final value, the value a later
	/// edit was made from, or a superseded value handed to exactly one device to copy. Equal values count as the same,
	/// since two devices writing the same thing isn't a conflict.
	@Test(arguments: 2000 ..< 2150 as Range<UInt64>)
	func noEditDisappearsSilently(seed: UInt64) {
		var world = World(seed: seed, skew: true)
		for index in world.devices.indices {
			world.devices[index].syncUntilDone(with: &world.server)
		}
		for _ in 0 ..< 300 {
			world.step(Hazards())
		}
		world.settle()
		Self.expectConverged(world, seed: seed)

		var survivors: Set<String> = []
		func survived(_ key: SyncRecord.Key, _ field: String, _ value: JSONValue) {
			survivors.insert("\(key.kind.rawValue)/\(key.id)/\(field)/\(value)")
		}
		for (key, record) in world.server.records {
			for (field, value) in record.fields {
				survived(key, field, value.value)
			}
		}
		for write in world.history {
			if let parent = write.parent {
				survived(write.key, write.field, parent.value)
			}
		}
		let superseded = world.devices.flatMap(\.superseded)
		for lost in superseded {
			survived(lost.key, lost.field, lost.lost.value)
		}

		for write in world.history {
			let kept = survivors.contains("\(write.key.kind.rawValue)/\(write.key.id)/\(write.field)/\(write.edit.value)")
			#expect(kept, "Seed \(seed): \(write.key.id) \(write.field) = \(write.edit.value) disappeared")
		}

		// Each lost value is handed out once
		let lost = superseded.map { "\($0.key.id)/\($0.field)/\($0.lost.stamp)" }
		#expect(Set(lost).count == lost.count, "Seed \(seed): a superseded value was handed out twice")
	}
}
