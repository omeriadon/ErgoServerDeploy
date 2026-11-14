//
//  ErgoClient.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoProtocol
import Foundation
#if canImport(FoundationNetworking)
	import FoundationNetworking
#endif

/// Talks to the Ergo server. Everything it throws is a `ServiceError`, worded to show the user as is.
public struct ErgoClient: Sendable {
	public let server: URL

	/// Nil until an account exists, which only `createAccount` allows
	public let token: String?

	let session: URLSession

	public init(server: URL, token: String?, session: URLSession = .shared) {
		self.server = server
		self.token = token
		self.session = session
	}

	// MARK: - Account

	public func createAccount() async throws -> AccountCreated {
		try await send(request("POST", ErgoProtocol.Path.accounts, authorized: false))
	}

	public func deleteAccount() async throws {
		_ = try await data(for: request("DELETE", ErgoProtocol.Path.account))
	}

	/// Attaches this device's account to the Apple ID, or merges it into the account that already has it
	public func signInWithApple(identityToken: String, nonce: String, authorizationCode: String? = nil) async throws -> SignedIn {
		let body = SignInWithAppleRequest(identityToken: identityToken, nonce: nonce, authorizationCode: authorizationCode)
		return try await send(request("POST", ErgoProtocol.Path.appleSignIn, body: body))
	}

	/// Attaches an email and password to this device's account, so either way back in works. Throws `.emailInUse`
	/// when the email has an account already.
	public func register(email: String, password: String) async throws {
		let body = EmailCredentials(email: email, password: password)
		_ = try await data(for: request("POST", ErgoProtocol.Path.register, body: body))
	}

	/// Joins the account that has the email, merging this device's account into it. A wrong email or password
	/// throws `.invalidCredentials`, which is not `.unauthorized`: this device's token is still good.
	public func logIn(email: String, password: String) async throws -> SignedIn {
		let body = EmailCredentials(email: email, password: password)
		return try await send(request("POST", ErgoProtocol.Path.logIn, body: body))
	}

	/// Signs out every other device of the account, and keeps this one
	public func changePassword(current: String, new: String) async throws {
		let body = ChangePasswordRequest(current: current, new: new)
		_ = try await data(for: request("POST", ErgoProtocol.Path.password, body: body))
	}

	/// Forgets only this device's token. The account and its other devices stay signed in.
	public func signOut() async throws {
		_ = try await data(for: request("DELETE", ErgoProtocol.Path.accountToken))
	}

	// MARK: - Connections

	/// Without any for a provider or kind of credential this version doesn't know
	public func connections() async throws -> [ConnectionStatus] {
		let list: TolerantList<ConnectionStatus> = try await send(request("GET", ErgoProtocol.Path.connections))
		return list.elements
	}

	public func connect(_ provider: Provider, _ upload: ConnectionUpload) async throws -> ConnectionStatus {
		try await send(request("PUT", Self.connectionPath(provider), body: upload))
	}

	public func disconnect(_ provider: Provider) async throws {
		_ = try await data(for: request("DELETE", Self.connectionPath(provider)))
	}

	static func connectionPath(_ provider: Provider) -> String {
		ErgoProtocol.Path.connections + "/" + provider.rawValue
	}

	// MARK: - Sync

	/// One round trip both ways: pushes `body.changes`, then returns everything after `body.cursor`
	public func sync(_ body: SyncRequest) async throws -> SyncResponse {
		try await send(request("POST", ErgoProtocol.Path.sync, body: body))
	}

	// MARK: - Requests

	func request(_ method: String, _ path: String, authorized: Bool = true) -> URLRequest {
		var request = URLRequest(url: server.appending(path: path))
		request.httpMethod = method
		request.setValue(String(ErgoProtocol.version), forHTTPHeaderField: ErgoProtocol.versionHeader)
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		if authorized, let token {
			request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
		}
		return request
	}

	func request(_ method: String, _ path: String, authorized: Bool = true, body: some Encodable) throws -> URLRequest {
		var request = request(method, path, authorized: authorized)
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		do {
			request.httpBody = try ErgoProtocol.encoder.encode(body)
		} catch {
			throw ServiceError(code: .invalidRequest, message: "Couldn't encode the request")
		}
		return request
	}

	/// The same headers as REST, on a ws(s) URL
	func socketRequest(_ path: String) -> URLRequest {
		var request = request("GET", path)
		guard let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
			return request
		}
		components.scheme = url.scheme == "https" ? "wss" : "ws"
		request.url = components.url ?? url
		return request
	}

	func data(for request: URLRequest) async throws -> Data {
		let data: Data
		let response: URLResponse
		do {
			(data, response) = try await session.data(for: request)
		} catch {
			try Task.checkCancellation()
			throw ServiceError.unreachable(because: error, host: request.url?.host())
		}

		let status = (response as? HTTPURLResponse)?.statusCode ?? 0
		guard 200 ..< 300 ~= status else {
			let failure = (try? ErgoProtocol.decoder.decode(ServiceError.self, from: data))
				?? ServiceError(code: .internalError, message: "Unexpected status \(status) from the Ergo server")
			if failure.code == .outdatedApp {
				Self.announce(.required)
			}
			throw failure
		}
		if (response as? HTTPURLResponse)?.value(forHTTPHeaderField: ErgoProtocol.updateHeader) == AppUpdate.recommended.rawValue {
			Self.announce(.recommended)
		}
		return data
	}

	func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
		let data = try await data(for: request)
		do {
			return try ErgoProtocol.decoder.decode(Response.self, from: data)
		} catch {
			throw ServiceError.unexpectedReply
		}
	}

	// MARK: - Sockets

	/// Sends `opening`, then yields each message up to and including the one `isLast` picks.
	/// If the consumer is cancelled first, `closing` is sent before the socket closes, so the server stops too. If the
	/// connection just ends, as when the app is closed, nothing is sent, and a run that outlives its socket carries on.
	func messages<Message: Decodable & Sendable>(
		at path: String,
		opening: String? = nil,
		closing: String? = nil,
		isLast: @escaping @Sendable (Message) -> Bool
	) -> AsyncThrowingStream<Message, Error> {
		let socket = session.webSocketTask(with: socketRequest(path))

		return AsyncThrowingStream { continuation in
			let work = Task {
				socket.resume()
				defer { socket.cancel(with: .normalClosure, reason: nil) }

				do {
					if let opening {
						try await socket.send(.string(opening))
					}
					while true {
						// Nil is a kind this version doesn't know, from a newer server
						guard let message: Message = try await Self.decode(socket.receive()) else { continue }
						continuation.yield(message)
						if isLast(message) {
							break
						}
					}
					continuation.finish()
				} catch let error as ServiceError {
					continuation.finish(throwing: error)
				} catch {
					continuation.finish(throwing: Task.isCancelled ? CancellationError() : Self.failure(of: socket, error))
				}
			}

			continuation.onTermination = { termination in
				work.cancel()
				guard case .cancelled = termination else { return }
				Task {
					if let closing {
						try? await socket.send(.string(closing))
					}
					socket.cancel(with: .goingAway, reason: nil)
				}
			}
		}
	}

	static func text(_ message: some Encodable) -> String? {
		(try? ErgoProtocol.encoder.encode(message)).map { String(decoding: $0, as: UTF8.self) }
	}

	static func decode<Message: Decodable>(_ frame: URLSessionWebSocketTask.Message) throws -> Message? {
		let data: Data
		switch frame {
			case let .string(text):
				data = Data(text.utf8)
			case let .data(value):
				data = value
			@unknown default:
				throw ServiceError.unexpectedReply
		}

		do {
			return try ErgoProtocol.decoder.decode(Message.self, from: data)
		} catch {
			if let skipping = Message.self as? any SkipsUnknownKinds.Type, skipping.canSkip(data) {
				return nil
			}
			throw ServiceError.unexpectedReply
		}
	}

	/// The task's own error is the first thing that went wrong. `thrown` can be a later one, like "not connected".
	static func failure(of socket: URLSessionWebSocketTask, _ thrown: any Error) -> ServiceError {
		let failure = failure(
			status: (socket.response as? HTTPURLResponse)?.statusCode,
			error: socket.error ?? thrown,
			host: socket.originalRequest?.url?.host()
		)
		if failure.code == .outdatedApp {
			announce(.required)
		}
		return failure
	}

	// MARK: - Updates

	/// Posted whenever the server says this app is getting old or is too old, with the `AppUpdate` as its object. It can
	/// come many times a minute and from any thread, so whoever shows it decides how often.
	public static let appUpdateNotification = Notification.Name("ErgoClient.appUpdate")

	static func announce(_ update: AppUpdate) {
		NotificationCenter.default.post(name: appUpdateNotification, object: update)
	}

	/// The upgrade's status comes first, a socket can't carry an error body. No status means no HTTP reply at all.
	static func failure(status: Int?, error: any Error, host: String?) -> ServiceError {
		switch status {
			case 101?:
				.disconnected(because: error, host: host)
			case 401?:
				ServiceError(code: .unauthorized, message: "Unknown Ergo account")
			case 403?:
				ServiceError(code: .signInRequired, message: "Sign in to sync")
			case 426?:
				.outdated
			case let status?:
				.unreachable("the server answered HTTP \(status) to the WebSocket upgrade")
			case nil:
				.unreachable(because: error, host: host)
		}
	}
}

extension ServiceError {
	static let unreachable = ServiceError(code: .providerUnavailable, message: "Couldn't reach the Ergo server")
	static let disconnected = ServiceError(code: .providerUnavailable, message: "Lost connection to the Ergo server")
	static let unexpectedReply = ServiceError(code: .internalError, message: "Unexpected reply from the Ergo server")

	/// A socket's upgrade can't carry the server's own message
	static let outdated = ServiceError(code: .outdatedApp, message: "Expected a newer version of Ergo, update the app")
}
