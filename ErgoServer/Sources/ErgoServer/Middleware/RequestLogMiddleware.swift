//
//  RequestLogMiddleware.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoProtocol
import Vapor

/// The status each request got, so a socket upgrade shows as 101, or as whatever turned it away. Outermost, so it sees
/// the status `ServiceErrorMiddleware` chose and the logger `AccountAuthenticator` made for the account.
///
/// A verbose account (`VerboseAccounts`) gets a line for every request, with its real path. Everyone else gets nothing
/// while it works, and a `warning` for a failure: the route as written in `routes.swift` (so no board, member or invite
/// token; see `path(of:)` for a request that never got to a route), the status and the `ServiceError` code. A failure that can repeat (a dead token the app retries) is said once a
/// minute with how many were left out. A 500 is `ServiceErrorMiddleware`'s own `error` line, with what went wrong.
///
/// Never the query, headers or body, and no token from an ask's tool URL or an invite link.
struct RequestLogMiddleware: AsyncMiddleware {
	func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
		let start = ContinuousClock.now
		let response: Response
		do {
			response = try await next.respond(to: request)
		} catch {
			request.logger.error("\(request.method) \(Self.path(of: request)) failed", metadata: ["error": "\(request.logger.reason(for: error))"])
			throw error
		}
		Self.log(request, status: response.status, since: start)
		return response
	}

	static func log(_ request: Request, status: HTTPResponseStatus, since start: ContinuousClock.Instant) {
		let logger = request.logger
		let upgrade = request.headers.first(name: .upgrade)?.lowercased() == "websocket" ? " (WebSocket upgrade)" : ""
		let line = "\(request.method) \(path(of: request)) \(status.code)\(upgrade)"
		var metadata: Logger.Metadata = ["duration": "\(start.duration(to: .now))"]

		// A CLI asks for server messages and to end its session on every run, and is told this server has neither
		let isRoutine = status == .methodNotAllowed && AskToolController.isToolCall(request)
		guard status.code >= 400, !isRoutine else {
			logger.verbose("\(line)", metadata: metadata)
			return
		}

		let code = request.failureCode
		if let code {
			metadata["code"] = "\(code)"
		}
		// Said already, with the error
		guard status != .internalServerError else {
			logger.verbose("\(line)", metadata: metadata)
			return
		}
		if !logger.isVerbose {
			let key = "\(request.method) \(path(of: request)) \(status.code) \(code ?? "")"
			guard let leftOut = request.ergo.logThrottle.allow(key) else { return }
			if leftOut > 0 {
				metadata["leftOut"] = "\(leftOut)"
			}
		}
		logger.warning("\(line)", metadata: metadata)
	}

	/// A verbose account's own path, without a token. Anyone else's is the route, so ids in it are never logged. A request
	/// turned away before it was routed (an app that's too old) has no route, so each part of its path that no route has is
	/// `:value`: neither an id nor an invite token nor whatever a scanner tried gets through.
	static func path(of request: Request) -> String {
		if request.logger.isVerbose {
			return AskToolController.isToolCall(request) ? "/\(ErgoProtocol.Path.askTools)" : JoinController.loggablePath(of: request)
		}
		if let route = request.route {
			return "/" + route.path.map { "\($0)" }.joined(separator: "/")
		}

		let known = Set(request.application.routes.all.flatMap(\.path).compactMap { component -> String? in
			if case let .constant(name) = component {
				name
			} else {
				nil
			}
		})
		return "/" + request.url.path.split(separator: "/").map { known.contains(String($0)) ? String($0) : ":value" }.joined(separator: "/")
	}
}
