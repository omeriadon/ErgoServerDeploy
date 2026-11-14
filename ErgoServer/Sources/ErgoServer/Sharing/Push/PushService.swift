//
//  PushService.swift
//  ErgoServer
//
//  Created by Adon Omeri on 7/11/2026.
//

import ErgoProtocol
import Fluent
import Foundation
import Logging

/// Something on a shared board worth telling people, decided inside a transaction and sent after it commits
struct PushEvent: Sendable, Hashable {
	let board: String

	/// The alert's title: "Sam joined"
	let heading: String

	/// The board's title, nil when there's none to show. Never logged.
	let title: String?
	let recipients: [UUID]

	/// Edits are throttled, everything else always alerts
	var isEdit = false

	/// Only syncs the device, with no alert
	var isSilent = false

	/// What a push says when the owner's device sent no title
	static let untitled = "a board"

	var alert: PushMessage.Alert {
		PushMessage.Alert(title: heading, body: title ?? Self.untitled)
	}
}

/// Turns events into notifications for the devices that haven't already heard: one with an open live socket gets
/// nothing. Never fails what caused it, and logs no tokens, titles or names.
struct PushService: Sendable {
	let sender: PushSender
	let live: SyncLive

	/// For a failure to reach someone, which is about them and not whoever's change it was
	let verbose: VerboseAccounts
	let throttle = PushThrottle()

	/// Finds the devices now, and sends in a detached task. `database` should be one the request can give up.
	func deliver(_ events: [PushEvent], on database: any Database, logger: Logger) async {
		let accounts = Set(events.flatMap(\.recipients))
		guard sender.isEnabled, !accounts.isEmpty else { return }

		let devices: [PushDeviceRow]
		do {
			devices = try await PushDeviceRow.query(on: database).filter(\.$account.$id ~~ Array(accounts)).all()
		} catch {
			logger.warning("Couldn't find devices for a push", metadata: ["error": "\(String(reflecting: type(of: error)))"])
			return
		}
		let reachable = Dictionary(grouping: devices.filter { !live.isListening(token: $0.$token.id) }) { $0.$account.id }

		var messages: [(message: PushMessage, device: UUID?, account: UUID)] = []
		for event in events {
			for account in event.recipients {
				guard let devices = reachable[account], !devices.isEmpty else { continue }
				var alert: PushMessage.Alert? = event.isSilent ? nil : event.alert
				if event.isEdit {
					switch throttle.decide(board: event.board, account: account) {
						case .alert:
							break
						case .silent:
							alert = nil
						case .nothing:
							continue
					}
				}
				for device in devices {
					let message = PushMessage(
						deviceToken: device.apnsToken,
						board: event.board,
						alert: alert
					)
					messages.append((message, device.id, account))
				}
			}
		}
		guard !messages.isEmpty else { return }

		let sender = sender
		let sending = messages
		// Each failure is about the person it was for: a push that Apple refused is a warning, with their pseudonym
		let loggers = Dictionary(uniqueKeysWithValues: accounts.map { ($0, verbose.logger(for: $0, from: logger)) })
		Task.detached {
			for (message, device, account) in sending {
				let log = loggers[account] ?? logger
				switch await sender.send(message) {
					case .sent:
						break
					case .deviceGone:
						if let device {
							await Self.forget(device, on: database, logger: log)
						}
					case let .failed(reason):
						log.warning("Couldn't send a push", metadata: ["reason": "\(reason)"])
				}
			}
		}
	}

	/// By row id, so no query carries the token. A few tries, since SQLite can briefly refuse a write on another connection.
	private static func forget(_ device: UUID, on database: any Database, logger: Logger) async {
		for attempt in 1 ... 3 {
			do {
				try await PushDeviceRow.query(on: database).filter(\.$id == device).delete()
				return
			} catch {
				if attempt == 3 {
					logger.warning("Couldn't forget a dead push device", metadata: ["error": "\(String(reflecting: type(of: error)))"])
				} else {
					try? await Task.sleep(for: .milliseconds(100))
				}
			}
		}
	}
}
