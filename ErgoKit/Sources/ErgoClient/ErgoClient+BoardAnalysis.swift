//
//  ErgoClient+BoardAnalysis.swift
//  ErgoKit
//
//  Created by Adon Omeri on 8/11/2026.
//

import ErgoProtocol
import Foundation
#if canImport(FoundationNetworking)
	import FoundationNetworking
#endif

public extension ErgoClient {
	// MARK: - Board analysis

	/// Hands the board to the server, which carries on without this request. Its results arrive as sync records.
	/// The board must already be synced.
	func startBoardAnalysis(board: String, _ body: BoardAnalysisRequest) async throws {
		_ = try await data(for: request("POST", ErgoProtocol.Path.boardAnalysis(board), body: body))
	}

	/// Stops the board's run, keeping what it has written
	func stopBoardAnalysis(board: String) async throws {
		_ = try await data(for: request("DELETE", ErgoProtocol.Path.boardAnalysis(board)))
	}
}
