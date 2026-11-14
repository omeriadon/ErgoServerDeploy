//
//  SyncLimit.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import Foundation

/// What the server accepts, shared so the app never builds a request that's refused forever
public enum SyncLimit {
	/// Request body
	public static let requestBytes = 1 << 20

	/// Any one field value, as compact JSON (`JSONValue.byteCount`)
	public static let valueBytes = 256 << 10

	/// Every canvas box and arrow is a record, so a big board alone is a few hundred
	public static let recordsPerAccount = 50000
	public static let requestsPerMinute = 60

	/// Everyone on a shared board, owner included
	public static let membersPerBoard = 30

	/// `SyncRequest.limit`
	public static let defaultRecords = 500
	public static let maxRecords = 1000

	/// How far ahead of the server's clock a stamp may be, in milliseconds
	public static let futureStamp: Int64 = 10 * 60000

	/// Tombstones older than this are pruned
	public static let tombstoneDays = 90
}

public extension JSONValue {
	/// The size of its compact JSON, which is what `SyncLimit.valueBytes` limits
	var byteCount: Int {
		(try? JSONEncoder().encode(self).count) ?? 0
	}
}
