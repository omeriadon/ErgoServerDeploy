//
//  Unreachable.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoProtocol
import Foundation
#if canImport(FoundationNetworking)
	import FoundationNetworking
#endif

/// Why the server couldn't be reached, in a few words, so "Couldn't reach the Ergo server" never stands alone.
/// Only the host goes in a message, never a whole URL, which could carry a token.
extension ServiceError {
	/// "Couldn't reach the Ergo server: connection refused", or the error's code when there's nothing better to say
	static func unreachable(because error: any Error, host: String?) -> ServiceError {
		guard let reason = Unreachable.reason(for: error, host: host) else {
			let error = error as NSError
			let code = error.domain == NSURLErrorDomain ? "URLError \(error.code)" : "\(error.domain) \(error.code)"
			return ServiceError(code: unreachable.code, message: "\(unreachable.message) (\(code))")
		}
		return unreachable(reason)
	}

	static func unreachable(_ reason: String) -> ServiceError {
		ServiceError(code: unreachable.code, message: "\(unreachable.message): \(reason)")
	}

	/// After the upgrade, so it's the connection that went, not the way to the server
	static func disconnected(because error: any Error, host: String?) -> ServiceError {
		guard let reason = Unreachable.reason(for: error, host: host) else { return disconnected }
		return ServiceError(code: disconnected.code, message: "\(disconnected.message): \(reason)")
	}
}

enum Unreachable {
	/// Nil when the error says nothing a person could act on
	static func reason(for error: any Error, host: String?) -> String? {
		let error = error as NSError
		let host = host.map(bare)

		// iOS says this in the path, whatever code the error has
		if deniesLocalNetwork(error) {
			return "local network access is off for Ergo, turn it on in Settings > Privacy & Security > Local Network"
		}

		switch error.domain {
			case NSURLErrorDomain:
				return reason(for: URLError(URLError.Code(rawValue: error.code), userInfo: error.userInfo), host: host)
			case NSPOSIXErrorDomain:
				return POSIXErrorCode(rawValue: Int32(error.code)).flatMap { reason(for: $0, host: host) }
			default:
				return nil
		}
	}

	private static func reason(for error: URLError, host: String?) -> String? {
		let local = host.map(isLocal) ?? false

		switch error.code {
			case .cannotFindHost, .dnsLookupFailed:
				return host.map { "the host '\($0)' wasn't found" } ?? "the host wasn't found"
			case .cannotConnectToHost:
				return local ? "connection refused, check ErgoServer is running with '--hostname 0.0.0.0'" : "connection refused"
			case .timedOut:
				// An unknown .local name never fails to resolve, it only times out
				if let host, host.hasSuffix(".local") {
					return "timed out, check '\(host)' is the Mac's name and both are on the same network"
				}
				return "timed out"
			case .appTransportSecurityRequiresSecureConnection:
				return "App Transport Security blocked the plain-text connection"
			case .notConnectedToInternet:
				switch error.networkUnavailableReason {
					case .cellular?:
						return "cellular data is off for Ergo"
					case .constrained?:
						return "Low Data Mode is on"
					case .expensive?:
						return "Ergo can't use expensive networks"
					default:
						return local ? "not connected to a network, or local network access is off for Ergo" : "not connected to the internet"
				}
			case .dataNotAllowed, .internationalRoamingOff:
				return "cellular data is off for Ergo"
			case .networkConnectionLost:
				return "the connection dropped"
			case .secureConnectionFailed:
				return "the TLS handshake failed"
			case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateHasBadDate, .serverCertificateNotYetValid:
				return "the server's TLS certificate isn't trusted"
			case .clientCertificateRejected, .clientCertificateRequired:
				return "the server asked for a TLS client certificate"
			case .badServerResponse, .cannotParseResponse:
				return "the reply wasn't valid HTTP"
			case .badURL, .unsupportedURL:
				return "the address isn't a server URL"
			default:
				return nil
		}
	}

	/// Sockets sometimes fail with the system's own errors instead of a URLError
	private static func reason(for code: POSIXErrorCode, host: String?) -> String? {
		switch code {
			case .ECONNREFUSED:
				"connection refused"
			case .ETIMEDOUT:
				"timed out"
			case .ECONNRESET:
				"the connection was reset"
			case .ENOTCONN:
				"the connection closed"
			case .EHOSTUNREACH, .ENETUNREACH:
				host.map { "no route to '\($0)'" } ?? "no route to the host"
			case .ENETDOWN:
				"the network is down"
			default:
				nil
		}
	}

	/// An unsatisfied path reads "unsatisfied (Local network prohibited)". It's only in its description, not in API.
	static func deniesLocalNetwork(_ error: NSError) -> Bool {
		let descriptions = error.userInfo.values.map { String(describing: $0) }
		if descriptions.contains(where: { $0.localizedCaseInsensitiveContains("local network prohibited") }) {
			return true
		}
		return (error.userInfo[NSUnderlyingErrorKey] as? NSError).map(deniesLocalNetwork) ?? false
	}

	/// Unqualified names, .local names and private or link-local addresses, everything local network privacy covers
	static func isLocal(_ host: String) -> Bool {
		let host = bare(host).lowercased()
		if host.hasSuffix(".local") || (!host.contains(".") && !host.contains(":")) {
			return true
		}
		if host.contains(":") {
			return host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd")
		}

		let octets = host.split(separator: ".").compactMap { UInt8($0) }
		guard octets.count == 4 else { return false }
		switch (octets[0], octets[1]) {
			case (10, _), (127, _), (192, 168), (169, 254):
				return true
			case (172, 16 ... 31):
				return true
			default:
				return false
		}
	}

	/// No IPv6 brackets and no trailing root dot
	private static func bare(_ host: String) -> String {
		var host = host
		if host.hasPrefix("["), host.hasSuffix("]") {
			host = String(host.dropFirst().dropLast())
		}
		if host.hasSuffix(".") {
			host.removeLast()
		}
		return host
	}
}
