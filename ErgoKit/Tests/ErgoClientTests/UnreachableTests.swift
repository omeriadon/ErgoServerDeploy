//
//  UnreachableTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

@testable import ErgoClient
import ErgoProtocol
import Foundation
import Testing

/// "Couldn't reach the Ergo server" always says why, when there's a why
struct UnreachableTests {
	static let mac = "Adons-Mac.local"

	func message(_ error: any Error, host: String? = Self.mac) -> String {
		ServiceError.unreachable(because: error, host: host).message
	}

	// MARK: - Reasons

	@Test(arguments: [
		(URLError.Code.cannotFindHost, "the host 'Adons-Mac.local' wasn't found"),
		(.dnsLookupFailed, "the host 'Adons-Mac.local' wasn't found"),
		(.cannotConnectToHost, "connection refused, check ErgoServer is running with '--hostname 0.0.0.0'"),
		(.timedOut, "timed out, check 'Adons-Mac.local' is the Mac's name and both are on the same network"),
		(.appTransportSecurityRequiresSecureConnection, "App Transport Security blocked the plain-text connection"),
		(.notConnectedToInternet, "not connected to a network, or local network access is off for Ergo"),
		(.networkConnectionLost, "the connection dropped"),
		(.dataNotAllowed, "cellular data is off for Ergo"),
		(.secureConnectionFailed, "the TLS handshake failed"),
		(.serverCertificateUntrusted, "the server's TLS certificate isn't trusted"),
		(.serverCertificateHasBadDate, "the server's TLS certificate isn't trusted"),
		(.clientCertificateRequired, "the server asked for a TLS client certificate"),
		(.badServerResponse, "the reply wasn't valid HTTP"),
		(.unsupportedURL, "the address isn't a server URL"),
	])
	func urlErrorsSayWhy(code: URLError.Code, reason: String) {
		#expect(message(URLError(code)) == "Couldn't reach the Ergo server: \(reason)")
		#expect(ServiceError.unreachable(because: URLError(code), host: Self.mac).code == .providerUnavailable)
	}

	@Test func hintsAboutTheMacOnlyForLocalHosts() {
		let host = "ergo.example.com"
		#expect(message(URLError(.cannotConnectToHost), host: host) == "Couldn't reach the Ergo server: connection refused")
		#expect(message(URLError(.timedOut), host: host) == "Couldn't reach the Ergo server: timed out")
		#expect(message(URLError(.notConnectedToInternet), host: host) == "Couldn't reach the Ergo server: not connected to the internet")
		#expect(message(URLError(.cannotFindHost), host: nil) == "Couldn't reach the Ergo server: the host wasn't found")
	}

	/// iOS puts this in the error's path, under any code
	@Test func localNetworkDenialIsNamed() {
		let path = "satisfied (Path is satisfied), interface: en0[802.11]; unsatisfied (Local network prohibited), interface: en0"
		let denied = URLError(.notConnectedToInternet, userInfo: ["_NSURLErrorNWPathKey": path])
		#expect(message(denied) == "Couldn't reach the Ergo server: local network access is off for Ergo, turn it on in Settings > Privacy & Security > Local Network")

		let underlying = NSError(domain: "kCFErrorDomainCFNetwork", code: -1009, userInfo: ["_NSURLErrorNWPathKey": path])
		let wrapped = URLError(.cannotConnectToHost, userInfo: [NSUnderlyingErrorKey: underlying])
		#expect(message(wrapped).hasSuffix("local network access is off for Ergo, turn it on in Settings > Privacy & Security > Local Network"))
	}

	@Test func posixErrorsSayWhy() {
		#expect(message(POSIXError(.ECONNREFUSED)) == "Couldn't reach the Ergo server: connection refused")
		#expect(message(POSIXError(.ECONNRESET)) == "Couldn't reach the Ergo server: the connection was reset")
		#expect(message(POSIXError(.EHOSTUNREACH)) == "Couldn't reach the Ergo server: no route to 'Adons-Mac.local'")
	}

	@Test func unknownCausesGiveTheirCode() {
		#expect(message(URLError(.httpTooManyRedirects)) == "Couldn't reach the Ergo server (URLError -1007)")
		#expect(message(NSError(domain: "Elsewhere", code: 7)) == "Couldn't reach the Ergo server (Elsewhere 7)")
	}

	@Test func localHosts() {
		for host in ["Adons-Mac.local", "adons-mac.local.", "mac", "192.168.1.20", "10.0.0.4", "172.20.1.1", "169.254.3.3", "[fe80::1]", "::1"] {
			#expect(Unreachable.isLocal(host), "\(host)")
		}
		for host in ["ergo.example.com", "8.8.8.8", "172.32.0.1", "2001:db8::1"] {
			#expect(!Unreachable.isLocal(host), "\(host)")
		}
	}

	// MARK: - Sockets

	@Test func theUpgradeStatusComesFirst() {
		let error = URLError(.badServerResponse)
		#expect(ErgoClient.failure(status: 404, error: error, host: Self.mac)
			== ServiceError(code: .providerUnavailable, message: "Couldn't reach the Ergo server: the server answered HTTP 404 to the WebSocket upgrade"))
		#expect(ErgoClient.failure(status: 401, error: error, host: Self.mac) == ServiceError(code: .unauthorized, message: "Unknown Ergo account"))
		#expect(ErgoClient.failure(status: 403, error: error, host: Self.mac) == ServiceError(code: .signInRequired, message: "Sign in to sync"))
	}

	@Test func noUpgradeMeansNoConnection() {
		#expect(ErgoClient.failure(status: nil, error: URLError(.appTransportSecurityRequiresSecureConnection), host: Self.mac).message
			== "Couldn't reach the Ergo server: App Transport Security blocked the plain-text connection")
	}

	@Test func afterTheUpgradeItsADisconnection() {
		#expect(ErgoClient.failure(status: 101, error: URLError(.timedOut), host: "ergo.example.com")
			== ServiceError(code: .providerUnavailable, message: "Lost connection to the Ergo server: timed out"))
		#expect(ErgoClient.failure(status: 101, error: URLError(.cancelled), host: "ergo.example.com") == .disconnected)
	}

	// MARK: - REST

	@Test(arguments: [
		(URLError.Code.cannotFindHost, "the host 'missing.example.com' wasn't found"),
		(.appTransportSecurityRequiresSecureConnection, "App Transport Security blocked the plain-text connection"),
		(.timedOut, "timed out"),
	])
	func restKeepsTheCause(code: URLError.Code, reason: String) async throws {
		let client = try ErgoClient(server: #require(URL(string: "https://missing.example.com")), token: "token", session: FailingServer.session(code))
		await #expect(throws: ServiceError(code: .providerUnavailable, message: "Couldn't reach the Ergo server: \(reason)")) {
			try await client.connections()
		}
	}
}

// MARK: - Stub

/// Fails every request the way URLSession would, with the code its session was made for
final class FailingServer: URLProtocol {
	static let codeHeader = "Failing-Server-Code"

	/// The code rides along on each request, since the system makes the protocol instances
	static func session(_ code: URLError.Code) -> URLSession {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [FailingServer.self]
		configuration.httpAdditionalHeaders = [codeHeader: String(code.rawValue)]
		return URLSession(configuration: configuration)
	}

	override class func canInit(with _: URLRequest) -> Bool {
		true
	}

	override class func canonicalRequest(for request: URLRequest) -> URLRequest {
		request
	}

	override func startLoading() {
		let code = request.value(forHTTPHeaderField: Self.codeHeader).flatMap(Int.init) ?? URLError.Code.unknown.rawValue
		client?.urlProtocol(self, didFailWithError: URLError(URLError.Code(rawValue: code)))
	}

	override func stopLoading() {}
}
