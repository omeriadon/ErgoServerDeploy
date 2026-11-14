//
//  ConnectionController.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoProtocol
import Fluent
import Foundation
import Vapor

/// `GET v1/connections`, and `PUT` or `DELETE v1/connections/<provider>`
enum ConnectionController {
	static func list(_ request: Request) async throws -> Response {
		let credentials = try await Credential.query(on: request.db)
			.filter(\.$account.$id == request.accountID)
			.all()
		var statuses = credentials.map(\.status)

		// The server's own key is always working as far as this account is concerned, so it's listed as connected
		if request.ergo.config.openRouter != nil {
			statuses.append(ConnectionStatus(provider: .openrouter, kind: .apiKey, verified: nil, problem: nil))
		}
		return try Response.json(statuses.sorted { $0.provider.rawValue < $1.provider.rawValue })
	}

	/// Only stored once a real call with it worked, so a typo never replaces a working connection
	static func connect(_ request: Request) async throws -> Response {
		let provider = try provider(of: request)
		try requireUserManaged(provider)
		let upload = try request.decode(ConnectionUpload.self)
		let secret = upload.secret.trimmingCharacters(in: .whitespacesAndNewlines)

		if let problem = problem(with: secret, kind: upload.kind, for: provider) {
			throw ServiceError(code: .invalidRequest, message: problem)
		}

		let status = try await store(
			ProviderCredential(provider: provider, kind: upload.kind, secret: Secret(secret)),
			account: request.accountID,
			on: request
		)
		return try Response.json(status)
	}

	static func disconnect(_ request: Request) async throws -> Response {
		let provider = try provider(of: request)
		try requireUserManaged(provider)
		try await Credential.query(on: request.db)
			.filter(\.$account.$id == request.accountID)
			.filter(\.$provider == provider)
			.delete()
		request.logger.verbose("Disconnected a provider", metadata: ["provider": "\(provider)"])
		return Response(status: .noContent)
	}

	// MARK: - Storing

	/// Verifies, then replaces whatever was stored for that provider. Under the account's single flight,
	/// so a check can't spend a Codex refresh token a running translation still needs.
	static func store(_ credential: ProviderCredential, account: UUID, on request: Request) async throws -> ConnectionStatus {
		let services = request.ergo

		return try await services.translations.exclusive(for: account) {
			let secret: Secret
			do {
				secret = try await services.verifier(credential, logger: request.logger)
			} catch let failure as ProviderFailure {
				request.logger.warning("Connection check failed", metadata: ["provider": "\(credential.provider)", "code": "\(failure.serviceError.code)"])
				throw failure.serviceError
			}

			let sealed = try services.vault.seal(secret, account: account, provider: credential.provider)
			let now = Date.now

			let status = try await request.db.transaction { database in
				try await Credential.query(on: database)
					.filter(\.$account.$id == account)
					.filter(\.$provider == credential.provider)
					.delete()

				let stored = Credential(
					account: account,
					provider: credential.provider,
					kind: credential.kind,
					sealed: sealed,
					verified: now,
					problem: nil,
					now: now
				)
				try await stored.save(on: database)
				return stored.status
			}
			request.logger.verbose("Connected a provider", metadata: ["provider": "\(credential.provider)", "kind": "\(credential.kind)"])
			return status
		}
	}

	// MARK: - Checking uploads

	static func provider(of request: Request) throws -> Provider {
		let name = request.parameters.get("provider") ?? ""
		guard let provider = Provider(rawValue: name) else {
			let known = Provider.allCases.map { "'\($0.rawValue)'" }.joined(separator: " or ")
			throw ServiceError(code: .invalidRequest, message: "Unknown provider '\(name)', expected \(known)")
		}
		return provider
	}

	/// The server's own providers have nothing to upload or forget
	static func requireUserManaged(_ provider: Provider) throws {
		guard !provider.isServerManaged else {
			throw ServiceError(code: .invalidRequest, message: "Expected a provider you connect yourself, \(provider.displayName) is set up on the Ergo server")
		}
	}

	/// Catches the usual mix-ups before spending a call on them. Nil when it looks right.
	static func problem(with secret: String, kind: CredentialKind, for provider: Provider) -> String? {
		let looksLikeJSON = secret.hasPrefix("{")
		if secret.isEmpty {
			return "Expected a secret, found nothing"
		}
		if !looksLikeJSON, secret.contains(where: \.isWhitespace) {
			return "Expected a single token, found spaces or line breaks inside it"
		}

		switch (provider, kind) {
			case (.openrouter, _):
				return "Expected a provider you connect yourself, \(provider.displayName) is set up on the Ergo server"

			case (.claude, .subscription):
				if secret.hasPrefix("sk-ant-oat") {
					return nil
				}
				if secret.hasPrefix("sk-ant-api") {
					return "Expected a token from 'claude setup-token', found an API key"
				}
				return "Expected a token from 'claude setup-token', starting with 'sk-ant-oat'"

			case (.claude, .apiKey):
				if secret.hasPrefix("sk-ant-api") {
					return nil
				}
				if secret.hasPrefix("sk-ant-oat") {
					return "Expected an Anthropic API key, found a token from 'claude setup-token'"
				}
				return "Expected an Anthropic API key, starting with 'sk-ant-api'"

			case (.codex, .subscription):
				if secret.hasPrefix("sk-") {
					return "Expected the contents of '~/.codex/auth.json', found an API key"
				}
				return CodexAuthFile.problem(with: secret)

			case (.codex, .apiKey):
				if secret.hasPrefix("sk-ant-") {
					return "Expected an OpenAI API key, found an Anthropic one"
				}
				if secret.hasPrefix("sk-") {
					return nil
				}
				if looksLikeJSON {
					return "Expected an OpenAI API key, found 'auth.json', connect it as a ChatGPT login instead"
				}
				return "Expected an OpenAI API key, starting with 'sk-'"
		}
	}
}
