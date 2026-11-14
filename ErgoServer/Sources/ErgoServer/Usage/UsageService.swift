//
//  UsageService.swift
//  ErgoServer
//
//  Created by Adon Omeri on 10/11/2026.
//

import ErgoProtocol
import Fluent
import Foundation
import Logging
import Synchronization

/// What one run on the server's own model has used, added up as its calls finish
final class UsageMeter: Sendable {
	private struct Tokens {
		var input = 0
		var output = 0
	}

	/// The model this account's plan gets, nil for the server's usual one
	let model: String?
	private let tokens = Mutex(Tokens())

	init(model: String?) {
		self.model = model
	}

	func add(input: Int, output: Int) {
		tokens.withLock {
			$0.input += max(0, input)
			$0.output += max(0, output)
		}
	}

	func micros(at price: UsagePrice) -> Int {
		let tokens = tokens.withLock { $0 }
		return price.micros(inputTokens: tokens.input, outputTokens: tokens.output)
	}
}

/// How much of the server's own model each account may use, and what it has paid for. Someone's own Claude or ChatGPT
/// login costs the server nothing, so nothing here applies to it. See `Plans/11-Paid.md`.
struct UsageService: Sendable {
	let config: ServerConfig
	let deviceCheck: DeviceCheckClient?
	let appStore: AppStoreVerifier?

	init(config: ServerConfig) {
		self.config = config
		deviceCheck = config.deviceCheck.map(DeviceCheckClient.init(config:))
		appStore = config.appleRootCertificate.flatMap { try? AppStoreVerifier(rootCertificate: $0, bundleID: config.appleApplicationID) }
	}

	// MARK: - Plans

	/// A subscription that's run out is the free plan again
	func plan(of account: UUID, on database: any Database, now: Date = .now) async throws -> (plan: AccountPlan, row: AccountPlanRow?) {
		let row = try await AccountPlanRow.row(account, on: database)
		guard let row, row.plan == AccountPlan.plus.rawValue else {
			return (.free, row)
		}
		if let expires = row.expires, expires < now {
			return (.free, row)
		}
		return (.plus, row)
	}

	/// For what's only on the paid plan. Nothing is refused until `ERGO_ENFORCE_PLANS` is on.
	func requirePlus(_ account: UUID, for feature: String, on database: any Database) async throws {
		guard config.usage.enforcesPlans else { return }
		guard try await plan(of: account, on: database).plan == .plus else {
			throw ServiceError(code: .planRequired, message: "\(feature) needs Ergo Plus")
		}
	}

	/// With DeviceCheck set up, a free account has no allowance until a device claims one for it
	private func needsDeviceClaim(_ plan: AccountPlan, _ row: AccountPlanRow?) -> Bool {
		plan == .free && deviceCheck != nil && row?.deviceClaimed == nil
	}

	private static let unclaimed = ServiceError(code: .allowanceUsed, message: "Expected this device to have claimed its free allowance, open AI in Settings and try again")

	// MARK: - The daily allowance

	private func dailyAllowance(_ plan: AccountPlan) -> Int {
		plan == .plus ? config.usage.plusDailyMicros : config.usage.freeDailyMicros
	}

	/// Throws once today's allowance is gone. A run that's already going always finishes, since this is only asked first.
	@discardableResult
	func requireAllowance(for account: UUID, on database: any Database, now: Date = .now) async throws -> AccountPlan {
		let (plan, row) = try await plan(of: account, on: database, now: now)
		if needsDeviceClaim(plan, row) {
			throw Self.unclaimed
		}
		let used = try await UsagePeriodRow.row(account, UsagePeriod.day(of: now), on: database)?.micros ?? 0
		guard used < dailyAllowance(plan) else {
			let hours = max(1, Int((UsagePeriod.nextDay(after: now).timeIntervalSince(now) / 3600).rounded(.up)))
			throw ServiceError(
				code: .allowanceUsed,
				message: "Used today's allowance on \(Provider.openrouter.displayName), it starts again in \(hours == 1 ? "an hour" : "\(hours) hours")"
			)
		}
		return plan
	}

	/// Never fails what it's counting
	func record(_ meter: UsageMeter, for account: UUID, on database: any Database, logger: Logger, now: Date = .now) async {
		let micros = meter.micros(at: config.usage.price)
		guard micros > 0 else { return }
		do {
			try await UsagePeriodRow.add(micros: micros, runs: 0, to: UsagePeriod.day(of: now), for: account, on: database)
			logger.verbose("Counted usage", metadata: ["micros": "\(micros)"])
		} catch {
			logger.warning("Couldn't record usage", metadata: ["error": "\(String(reflecting: type(of: error)))"])
		}
	}

	// MARK: - Deep research

	private func deepResearchPerWeek(_ plan: AccountPlan) -> Int {
		plan == .plus ? config.usage.plusDeepPerWeek : config.usage.freeDeepPerWeek
	}

	/// Counted by the week and apart from the daily allowance, since one run would use all of a day's
	func requireDeepResearch(for account: UUID, on database: any Database, now: Date = .now) async throws {
		let (plan, row) = try await plan(of: account, on: database, now: now)
		if needsDeviceClaim(plan, row) {
			throw Self.unclaimed
		}
		let limit = deepResearchPerWeek(plan)
		let used = try await UsagePeriodRow.row(account, UsagePeriod.week(of: now), on: database)?.runs ?? 0
		guard used < limit else {
			throw ServiceError(
				code: .allowanceUsed,
				message: "Expected at most \(limit) deep research \(limit == 1 ? "run" : "runs") a week on \(Provider.openrouter.displayName), found this week's used"
			)
		}
	}

	/// `runs` is -1 to give back a run that failed before it found anything
	func recordDeepResearch(_ runs: Int = 1, for account: UUID, on database: any Database, logger: Logger, now: Date = .now) async {
		do {
			try await UsagePeriodRow.add(micros: 0, runs: runs, to: UsagePeriod.week(of: now), for: account, on: database)
			logger.verbose(runs < 0 ? "Gave back a deep research run" : "Counted a deep research run")
		} catch {
			logger.warning("Couldn't record a deep research run", metadata: ["error": "\(String(reflecting: type(of: error)))"])
		}
	}

	// MARK: - Status

	func status(of account: UUID, on database: any Database, now: Date = .now) async throws -> UsageStatus {
		let (plan, row) = try await plan(of: account, on: database, now: now)
		let used = try await UsagePeriodRow.row(account, UsagePeriod.day(of: now), on: database)?.micros ?? 0
		let runs = try await UsagePeriodRow.row(account, UsagePeriod.week(of: now), on: database)?.runs ?? 0
		let allowance = max(1, dailyAllowance(plan))
		let perWeek = deepResearchPerWeek(plan)
		return UsageStatus(
			plan: plan,
			plansEnforced: config.usage.enforcesPlans,
			fractionUsed: min(1, Double(used) / Double(allowance)),
			resets: UsagePeriod.nextDay(after: now),
			deepResearchLeft: max(0, perWeek - runs),
			deepResearchPerWeek: perWeek,
			needsDeviceClaim: needsDeviceClaim(plan, row)
		)
	}

	// MARK: - Paying

	/// Takes an App Store transaction as Apple signed it. One subscription pays for one account: the last to show it.
	func activate(_ upload: PlanUpload, for account: UUID, on database: any Database, logger: Logger, now: Date = .now) async throws {
		guard let appStore else {
			logger.warning("A purchase was refused, since purchases aren't set up")
			throw ServiceError(code: .providerUnavailable, message: "Purchases aren't set up on the Ergo server")
		}
		let transaction: AppStoreTransaction
		do {
			transaction = try await appStore.verified(upload.transaction)
		} catch {
			// Never the transaction: its ids are Apple's and the purchaser's
			logger.warning("A purchase didn't verify", metadata: ["reason": "\((error as? ServiceError)?.message ?? "unknown")"])
			throw error
		}
		let expires = transaction.expiresDate.map { Date(timeIntervalSince1970: $0 / 1000) }
		let isActive = transaction.revocationDate == nil && (expires.map { $0 > now } ?? true)

		let moved = try await database.transaction { database -> Int in
			let holders = try await AccountPlanRow.query(on: database).filter(\.$originalTransaction == transaction.originalTransactionId).all()
			var released = 0
			for holder in holders where holder.$account.id != account {
				holder.plan = AccountPlan.free.rawValue
				holder.expires = nil
				holder.originalTransaction = nil
				try await holder.save(on: database)
				released += 1
			}

			let row = try await AccountPlanRow.findOrMake(account, on: database)
			row.plan = (isActive ? AccountPlan.plus : AccountPlan.free).rawValue
			row.expires = expires
			row.originalTransaction = transaction.originalTransactionId
			try await row.save(on: database)
			return released
		}
		logger.verbose("Recorded a purchase", metadata: ["active": "\(isActive)", "movedFromAnotherAccount": "\(moved)"])
	}

	// MARK: - One free allowance per device

	/// Marks the account as having a device's free allowance. Apple keeps two bits per device and the month they were last
	/// set, which is all this needs: a device gives its allowance to one new account a month.
	func claimDevice(_ upload: DeviceClaimUpload, for account: UUID, on database: any Database, logger: Logger, now: Date = .now) async throws {
		guard let deviceCheck else { return }
		let row = try await AccountPlanRow.findOrMake(account, on: database)
		guard row.deviceClaimed == nil else { return }

		switch try await deviceCheck.claim(deviceToken: upload.token, logger: logger, now: now) {
			case .granted:
				row.deviceClaimed = now
				try await row.save(on: database)
				logger.verbose("Claimed this device's free allowance")
			case .claimedThisMonth:
				logger.warning("A device's free allowance had already moved this month")
				throw ServiceError(
					code: .invalidRequest,
					message: "This device's free allowance went to another Ergo account this month. Sign in to that one, connect your own Claude or ChatGPT, or try again next month"
				)
		}
	}
}
