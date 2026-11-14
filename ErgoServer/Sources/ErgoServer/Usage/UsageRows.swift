//
//  UsageRows.swift
//  ErgoServer
//
//  Created by Adon Omeri on 10/11/2026.
//

import Fluent
import Foundation

/// What an account has used of the server's own model in one period: a day's cost (`2026-11-10`), or a week's deep
/// research runs (`2026-W46`). See `UsagePeriod`.
final class UsagePeriodRow: Model, @unchecked Sendable {
	static let schema = "usage_periods"

	@ID(key: .id)
	var id: UUID?

	@Parent(key: "account_id")
	var account: Account

	@Field(key: "period")
	var period: String

	/// Millionths of a dollar, at the price in `ServerConfig.Usage`
	@Field(key: "micros")
	var micros: Int

	@Field(key: "runs")
	var runs: Int

	init() {}

	static func row(_ account: UUID, _ period: String, on database: any Database) async throws -> UsagePeriodRow? {
		try await query(on: database).filter(\.$account.$id == account).filter(\.$period == period).first()
	}

	/// Two calls ending at once can lose one of their counts, which only ever undercounts
	static func add(micros: Int, runs: Int, to period: String, for account: UUID, on database: any Database) async throws {
		if let existing = try await row(account, period, on: database) {
			existing.micros += micros
			existing.runs = max(0, existing.runs + runs)
			try await existing.save(on: database)
			return
		}

		let made = UsagePeriodRow()
		made.$account.id = account
		made.period = period
		made.micros = micros
		made.runs = max(0, runs)
		do {
			try await made.save(on: database)
		} catch {
			// Another call made this period's row first
			guard let existing = try await row(account, period, on: database) else {
				throw error
			}
			existing.micros += micros
			existing.runs = max(0, existing.runs + runs)
			try await existing.save(on: database)
		}
	}
}

/// What an account has paid for, and whether a device has claimed its free allowance. No row means free and unclaimed.
final class AccountPlanRow: Model, @unchecked Sendable {
	static let schema = "account_plans"

	@ID(key: .id)
	var id: UUID?

	@Parent(key: "account_id")
	var account: Account

	/// An `AccountPlan`'s raw value
	@Field(key: "plan")
	var plan: String

	/// When the subscription runs out, unless it's renewed first
	@OptionalField(key: "expires")
	var expires: Date?

	/// Apple's id for the subscription, so one purchase can't pay for two accounts
	@OptionalField(key: "original_transaction")
	var originalTransaction: String?

	@OptionalField(key: "device_claimed")
	var deviceClaimed: Date?

	init() {}

	static func row(_ account: UUID, on database: any Database) async throws -> AccountPlanRow? {
		try await query(on: database).filter(\.$account.$id == account).first()
	}

	/// The account's row, made if there's none yet. Not saved.
	static func findOrMake(_ account: UUID, on database: any Database) async throws -> AccountPlanRow {
		if let existing = try await row(account, on: database) {
			return existing
		}
		let made = AccountPlanRow()
		made.$account.id = account
		made.plan = "free"
		return made
	}
}
