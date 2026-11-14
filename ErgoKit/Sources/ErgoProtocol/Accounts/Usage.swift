//
//  Usage.swift
//  ErgoKit
//
//  Created by Adon Omeri on 10/11/2026.
//

import Foundation

/// What someone has paid for
public enum AccountPlan: String, Codable, Sendable, Hashable {
	case free, plus

	public init(from decoder: any Decoder) throws {
		self = try Self(rawValue: decoder.singleValueContainer().decode(String.self)) ?? .free
	}
}

/// `GET v1/usage`: how much of Ergo's model this account has left
public struct UsageStatus: Codable, Sendable, Hashable {
	public let plan: AccountPlan

	/// False until the App Store products exist. While it's false nothing is held back for being on the free plan.
	public let plansEnforced: Bool

	/// How much of today's allowance is gone, from 0 to 1
	public let fractionUsed: Double

	/// When the allowance starts again
	public let resets: Date

	public let deepResearchLeft: Int
	public let deepResearchPerWeek: Int

	/// This account has no free allowance yet, and the device has to claim one
	public let needsDeviceClaim: Bool

	public init(plan: AccountPlan, plansEnforced: Bool, fractionUsed: Double, resets: Date, deepResearchLeft: Int, deepResearchPerWeek: Int, needsDeviceClaim: Bool) {
		self.plan = plan
		self.plansEnforced = plansEnforced
		self.fractionUsed = fractionUsed
		self.resets = resets
		self.deepResearchLeft = deepResearchLeft
		self.deepResearchPerWeek = deepResearchPerWeek
		self.needsDeviceClaim = needsDeviceClaim
	}

	/// Whether what's only on the paid plan can be used
	public var hasPlusFeatures: Bool {
		plan == .plus || !plansEnforced
	}
}

/// `POST v1/account/plan`: an App Store transaction, as Apple signed it
public struct PlanUpload: Codable, Sendable, Hashable {
	public let transaction: String

	public init(transaction: String) {
		self.transaction = transaction
	}
}

/// `POST v1/account/device-claim`: a DeviceCheck token, for one free allowance per phone
public struct DeviceClaimUpload: Codable, Sendable, Hashable {
	public let token: String

	public init(token: String) {
		self.token = token
	}
}

/// What a call costs, in millionths of a dollar. Prices are dollars per million tokens, so a token at a price of 1 is
/// exactly one millionth of a dollar. A free model is still counted at a paid model's price, so the allowance means the same.
public struct UsagePrice: Codable, Sendable, Hashable {
	public let input: Double
	public let output: Double

	public init(input: Double, output: Double) {
		self.input = input
		self.output = output
	}

	public func micros(inputTokens: Int, outputTokens: Int) -> Int {
		Int((Double(inputTokens) * input + Double(outputTokens) * output).rounded(.up))
	}
}

/// The days and weeks allowances are counted in, always UTC so a device's time zone can't change them
public enum UsagePeriod {
	private static var calendar: Calendar {
		var calendar = Calendar(identifier: .iso8601)
		calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
		return calendar
	}

	public static func day(of date: Date) -> String {
		let parts = calendar.dateComponents([.year, .month, .day], from: date)
		return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
	}

	public static func week(of date: Date) -> String {
		let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
		return String(format: "%04d-W%02d", parts.yearForWeekOfYear ?? 0, parts.weekOfYear ?? 0)
	}

	public static func month(of date: Date) -> String {
		let parts = calendar.dateComponents([.year, .month], from: date)
		return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
	}

	/// The midnight after `date`
	public static func nextDay(after date: Date) -> Date {
		let calendar = calendar
		return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date.addingTimeInterval(86400)
	}
}

/// The App Store products that are the paid plan
public enum PlanProducts {
	public static let monthly = "com.adonis.Ergo.plus.monthly"
	public static let yearly = "com.adonis.Ergo.plus.yearly"
	public static let all = [monthly, yearly]
}
