//
//  ServiceErrorMiddleware.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoProtocol
import Foundation
import Vapor

/// Every error leaves as a `ServiceError` body, the only shape the app reads. Anything unexpected is logged and kept vague:
/// the route and, for a verbose account, what went wrong, otherwise only the kind of error, since a database's can quote what
/// was being saved. The code of every failure goes to `RequestLogMiddleware` for its line.
struct ServiceErrorMiddleware: AsyncMiddleware {
	func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
		do {
			return try await next.respond(to: request)
		} catch {
			let failure = Self.serviceError(for: error, path: request.url.path)
			request.failureCode = "\(failure.code)"
			if failure.code == .internalError {
				request.logger.error("Request failed", metadata: ["path": "\(RequestLogMiddleware.path(of: request))", "error": "\(request.logger.reason(for: error))"])
			}
			return try Response.json(failure, status: failure.status)
		}
	}

	static func serviceError(for error: any Error, path: String) -> ServiceError {
		switch error {
			case let error as ServiceError:
				error
			case let error as ProviderFailure:
				error.serviceError
			case is DecodingError:
				ServiceError(code: .invalidRequest, message: "Couldn't read the request body")
			case let error as any AbortError:
				switch error.status {
					case .unauthorized:
						.unknownAccount
					case .notFound:
						ServiceError(code: .invalidRequest, message: "Unknown path '\(path)'")
					case .payloadTooLarge:
						ServiceError(code: .tooLarge, message: "Request body is too large")
					case _ where error.status.code < 500:
						ServiceError(code: .invalidRequest, message: error.reason)
					default:
						.internalFailure
				}
			default:
				.internalFailure
		}
	}
}

extension ServiceError {
	static let unknownAccount = ServiceError(code: .unauthorized, message: "Unknown Ergo account")
	static let internalFailure = ServiceError(code: .internalError, message: "Something went wrong on the Ergo server")
	static let signInRequired = ServiceError(code: .signInRequired, message: "Sign in to sync")

	var status: HTTPResponseStatus {
		switch code {
			case .unauthorized: .unauthorized
			case .outdatedApp: .upgradeRequired
			case .invalidRequest: .badRequest
			case .notConnected: .conflict
			case .credentialRejected: .unprocessableEntity
			case .usageLimit: .tooManyRequests
			case .allowanceUsed: .tooManyRequests
			case .planRequired: .paymentRequired
			case .providerUnavailable: .badGateway
			case .busy: .conflict
			case .timedOut: .gatewayTimeout
			case .internalError: .internalServerError
			case .signInRequired: .forbidden
			case .syncResetRequired: .gone
			case .rateLimited: .tooManyRequests
			case .tooLarge: .payloadTooLarge
			// 401 like a dead token, but the code tells them apart and the app never reads the status
			case .invalidCredentials: .unauthorized
			case .emailInUse: .conflict
		}
	}
}

extension Response {
	/// Coded with `ErgoProtocol.encoder`, so dates are ISO 8601 like the app expects
	static func json(_ value: some Encodable, status: HTTPResponseStatus = .ok) throws -> Response {
		var headers = HTTPHeaders()
		headers.contentType = .json
		return try Response(status: status, headers: headers, body: .init(data: ErgoProtocol.encoder.encode(value)))
	}
}

extension Request {
	private struct FailureCodeKey: StorageKey {
		typealias Value = String
	}

	/// The `ServiceError` code this request was answered with, when it failed
	var failureCode: String? {
		get {
			storage[FailureCodeKey.self]
		}
		set {
			storage[FailureCodeKey.self] = newValue
		}
	}

	func decode<Value: Decodable>(_: Value.Type) throws -> Value {
		guard let body = body.data else {
			throw ServiceError(code: .invalidRequest, message: "Expected a JSON body")
		}
		return try ErgoProtocol.decoder.decode(Value.self, from: body)
	}
}
