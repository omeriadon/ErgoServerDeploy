//
//  configure.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import Fluent
import FluentPostgresDriver
import FluentSQLiteDriver
import Foundation
import Vapor

/// Reads the environment, then sets everything up
func configure(_ app: Application) async throws {
	var config = try ServerConfig.load(
		from: ProcessInfo.processInfo.environment,
		production: app.environment == .production,
		logger: app.logger
	)
	await CLIInstaller.ensure(&config, logger: app.logger)
	try await configure(app, config: config)
}

/// Tests pass their own config, a verifier that doesn't run a CLI, an Apple check that doesn't need Apple, a stand-in for
/// trading and revoking Apple's refresh tokens, and a push sender that doesn't need Apple either
func configure(
	_ app: Application,
	config: ServerConfig,
	verifier: ConnectionVerifier? = nil,
	apple: AppleTokenVerifier? = nil,
	push: PushSender? = nil,
	appleTokens: AppleRefreshTokens? = nil
) async throws {
	guard StagePrompts.missing.isEmpty else {
		throw ServerConfig.Problem(description: "Missing prompts for \(StagePrompts.missing.map { "'\($0)'" }.joined(separator: ", "))")
	}
	guard LegalController.missing.isEmpty else {
		throw ServerConfig.Problem(description: "Missing legal pages for \(LegalController.missing.map { "'\($0)'" }.joined(separator: ", "))")
	}

	if let user = config.runnerUser, ProcessRunner.Owner(named: user) == nil {
		throw ServerConfig.Problem(description: "ERGO_RUNNER_USER: Unknown user '\(user)'")
	}
	let sender = push ?? PushSender.live(config: config, client: { [weak app] in app?.client }, logger: app.logger)
	app.ergo = try ErgoServices(config: config, verifier: verifier, apple: apple, appleTokens: appleTokens, push: sender)
	if config.appleRootCertificate != nil, app.ergo.usage.appStore == nil {
		// The file has a certificate in it, but not one the verifier can use, and nothing else would say so until a purchase failed
		app.logger.error("ERGO_APPLE_ROOT_CERT_FILE isn't a certificate App Store purchases can be checked against, so they will be refused")
	}
	app.lifecycle.use(app.ergo.analyses.jobs)
	app.lifecycle.use(DetachedRunsShutdown(app.ergo.detached))
	app.passwords.use(.bcrypt(cost: config.passwordCost))

	if let postgres = config.postgres {
		// Trace, as this driver can't turn it off: SQL logs print the bound values, as below
		app.databases.use(.postgres(configuration: postgres, sqlLogLevel: .trace), as: .psql)
	} else if config.databasePath == ":memory:" {
		app.databases.use(.sqlite(.memory, sqlLogLevel: nil), as: .sqlite)
	} else {
		try createPrivately(config.databasePath)
		// No SQL debug log, since it prints the bound values: emails, password hashes and sealed credentials
		app.databases.use(.sqlite(.file(config.databasePath), sqlLogLevel: nil), as: .sqlite)
	}
	addMigrations(to: app)
	try await app.autoMigrate()
	if let interval = config.pruneInterval {
		app.lifecycle.use(SyncPruning(interval: interval))
	}

	// Replaces Vapor's own error middleware, so every error leaves as a ServiceError
	app.middleware = Middlewares()
	app.middleware.use(RequestLogMiddleware())
	app.middleware.use(ServiceErrorMiddleware())
	app.middleware.use(ProtocolVersionMiddleware())

	try routes(app)
}

/// In order, forever: a database only runs the ones it hasn't yet
func addMigrations(to app: Application) {
	app.migrations.add(CreateAccount())
	app.migrations.add(CreateCredential())
	app.migrations.add(CreateAccountToken())
	app.migrations.add(MoveAccountTokens())
	app.migrations.add(CreateSyncRecord())
	app.migrations.add(AddAccountEmail())
	app.migrations.add(AddSyncRecordBoard())
	app.migrations.add(CreateBoardSharing())
	app.migrations.add(DropPushDeviceEnvironment())
	app.migrations.add(CreateUsage())
	app.migrations.add(AddAppleRefreshToken())
	app.migrations.add(CreateReport())
}

/// SQLite creates the file with the umask's permissions, which would let the runner user read every sealed credential
private func createPrivately(_ path: String) throws {
	let files = FileManager.default
	guard !files.fileExists(atPath: path) else { return }

	try files.createDirectory(at: URL(filePath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
	guard files.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
		throw ServerConfig.Problem(description: "ERGO_DATABASE_PATH: Couldn't create '\(path)'")
	}
}
