//
//  JoinController.swift
//  ErgoServer
//
//  Created by Adon Omeri on 7/11/2026.
//

import ErgoProtocol
import Foundation
import Vapor

/// The two routes that have nothing to do with the app's protocol: the file that makes invite links open the app, and the
/// page someone without the app sees. Apple's CDN and browsers have never heard of the version header.
enum JoinController {
	// MARK: - Which requests

	/// What `ProtocolVersionMiddleware` lets through without the header
	static func isPublic(_ request: Request) -> Bool {
		guard request.method == .GET || request.method == .HEAD else { return false }
		let parts = request.url.path.split(separator: "/")
		return isJoinPage(request) || LegalController.isPage(parts) || parts == ErgoProtocol.Path.appleAppSiteAssociation.split(separator: "/")
	}

	/// The path holds an invite token, so it's never logged
	static func isJoinPage(_ request: Request) -> Bool {
		let parts = request.url.path.split(separator: "/")
		return parts.count > 1 && parts[0] == ErgoProtocol.Path.join
	}

	/// What the logs may say about this request's path
	static func loggablePath(of request: Request) -> String {
		isJoinPage(request) ? "/\(ErgoProtocol.Path.join)" : request.url.path
	}

	// MARK: - Apple App Site Association

	static func association(_ request: Request) async throws -> Response {
		var headers = HTTPHeaders()
		// Exactly this, with no charset, as Apple's docs ask
		headers.replaceOrAdd(name: .contentType, value: "application/json")
		let config = request.ergo.config
		return try Response(status: .ok, headers: headers, body: .init(data: associationFile(teamIDs: config.appleTeamIDs, bundleID: config.appleApplicationID)))
	}

	static func associationFile(teamIDs: [String], bundleID: String) throws -> Data {
		let detail = AssociationFile.Detail(appIDs: teamIDs.map { "\($0).\(bundleID)" }, components: [["/": "/\(ErgoProtocol.Path.join)/*"]])
		return try JSONEncoder().encode(AssociationFile(applinks: AssociationFile.Applinks(details: [detail])))
	}

	// MARK: - The page

	/// Reads nothing from the database, and says nothing about the board: anyone the link is forwarded to, and anything
	/// that fetches it for a preview, sees the same page.
	static func page(_ request: Request) async throws -> Response {
		var headers = HTTPHeaders()
		headers.contentType = .html
		headers.replaceOrAdd(name: "Referrer-Policy", value: "no-referrer")
		headers.replaceOrAdd(name: "X-Robots-Tag", value: "noindex")
		headers.replaceOrAdd(name: "Cache-Control", value: "no-store")
		let document = html(token: request.parameters.get("token") ?? "", appStoreID: request.ergo.config.appStoreID)
		return Response(status: .ok, headers: headers, body: .init(string: document))
	}

	static func html(token: String, appStoreID: String?) -> String {
		let encoded = token.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? ""
		let appLink = escaped("ergo://\(ErgoProtocol.Path.join)/\(encoded)")
		let storeMeta = appStoreID.map { #"<meta name="apple-itunes-app" content="app-id=\#(escaped($0))">"# } ?? ""
		let storeLink = appStoreID.map { #"<p><a href="https://apps.apple.com/app/id\#(escaped($0))">Get Ergo on the App Store</a></p>"# } ?? ""

		return """
		<!doctype html>
		<html lang="en">
		<head>
		<meta charset="utf-8">
		<meta name="viewport" content="width=device-width, initial-scale=1">
		<meta name="robots" content="noindex">
		<meta name="referrer" content="no-referrer">
		<meta property="og:title" content="An invitation to Ergo">
		\(storeMeta)
		<title>An invitation to Ergo</title>
		<style>
		:root { color-scheme: light dark; }
		body { font: 17px/1.5 -apple-system, system-ui, sans-serif; max-width: 30em; margin: 20vh auto 0; padding: 0 24px; text-align: center; }
		a { font-weight: 600; }
		</style>
		</head>
		<body>
		<h1>You've been invited to a board on Ergo</h1>
		<p><a href="\(appLink)">Open in Ergo</a></p>
		\(storeLink)
		</body>
		</html>
		"""
	}

	private static func escaped(_ text: String) -> String {
		text
			.replacingOccurrences(of: "&", with: "&amp;")
			.replacingOccurrences(of: "<", with: "&lt;")
			.replacingOccurrences(of: ">", with: "&gt;")
			.replacingOccurrences(of: "\"", with: "&quot;")
			.replacingOccurrences(of: "'", with: "&#39;")
	}
}

/// `{"applinks":{"details":[{"appIDs":[…],"components":[{"/":"/join/*"}]}]}}`
private struct AssociationFile: Encodable {
	struct Applinks: Encodable {
		let details: [Detail]
	}

	struct Detail: Encodable {
		let appIDs: [String]
		let components: [[String: String]]
	}

	let applinks: Applinks
}
