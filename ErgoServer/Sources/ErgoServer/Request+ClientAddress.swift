//
//  Request+ClientAddress.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import NIOCore
import Vapor

extension Request {
	/// Who is really asking, for the per-address limits. Behind a proxy every request comes from the proxy's
	/// own address, so with `ERGO_TRUST_PROXY` the address the proxy appended to `X-Forwarded-For` is used instead.
	var clientAddress: String {
		ClientAddress.resolve(
			peer: remoteAddress?.ipAddress,
			forwardedFor: headers[.xForwardedFor],
			trustProxy: application.ergo.config.trustProxy
		)
	}
}

enum ClientAddress {
	static let unknown = "unknown"

	/// The socket's own address, unless `trustProxy` and the socket is a local proxy (nginx on the same machine, or
	/// Traefik in another container, which connects from a private Docker address). Then it's the right-most `X-Forwarded-For` entry that isn't local itself: what the proxy appended is the
	/// only part of the header the client can't write, and everything left of it is the client's to make up.
	/// A request that reached the server directly is never trusted, whatever header it carries.
	static func resolve(peer: String?, forwardedFor: [String], trustProxy: Bool) -> String {
		guard let peer else { return unknown }
		guard trustProxy, isLocal(peer) else { return peer }

		let hops = forwardedFor.flatMap { $0.split(separator: ",") }.map { $0.trimmingCharacters(in: .whitespaces) }
		for hop in hops.reversed() {
			// Something that isn't an address means the proxy isn't what we think it is
			guard isAddress(hop) else { return peer }
			if !isLocal(hop) {
				return hop
			}
		}
		return peer
	}

	/// Loopback, or a private network: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 and fc00::/7
	private static func isLocal(_ address: String) -> Bool {
		var address = address.lowercased()
		if address.hasPrefix("::ffff:") {
			address.removeFirst("::ffff:".count)
		}
		if address == "::1" {
			return true
		}
		if let first = address.split(separator: ":", omittingEmptySubsequences: false).first, first.count == 4, address.contains(":") {
			return first.hasPrefix("fc") || first.hasPrefix("fd")
		}

		let octets = address.split(separator: ".").compactMap { UInt8($0) }
		guard octets.count == 4 else { return false }
		switch octets[0] {
			case 10, 127:
				return true
			case 172:
				return (16 ... 31).contains(octets[1])
			case 192:
				return octets[1] == 168
			default:
				return false
		}
	}

	private static func isAddress(_ text: String) -> Bool {
		(try? SocketAddress(ipAddress: text, port: 0)) != nil
	}
}
