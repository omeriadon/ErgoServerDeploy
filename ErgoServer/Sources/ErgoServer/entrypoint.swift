//
//  entrypoint.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import Logging
import Vapor

@main
enum Entrypoint {
	static func main() async throws {
		var environment = try Environment.detect()
		try LoggingSystem.bootstrap(from: &environment)

		let app = try await Application.make(environment)
		do {
			try await configure(app)
			try await app.execute()
		} catch {
			app.logger.report(error: error)
			try? await app.asyncShutdown()
			throw error
		}
		try await app.asyncShutdown()
	}
}
