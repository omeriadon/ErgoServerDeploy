//
//  CodexAuthFile.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import Foundation

/// `$CODEX_HOME/auth.json`, which is how a ChatGPT subscription is connected. Only checked, never rewritten:
/// it's stored as uploaded and handed back to Codex as is, so fields this doesn't know about survive.
enum CodexAuthFile {
	static let name = "auth.json"

	private struct Contents: Decodable {
		struct Tokens: Decodable {
			let accessToken: String?
			let refreshToken: String?

			enum CodingKeys: String, CodingKey {
				case accessToken = "access_token"
				case refreshToken = "refresh_token"
			}
		}

		let tokens: Tokens?
		let apiKey: String?

		enum CodingKeys: String, CodingKey {
			case tokens
			case apiKey = "OPENAI_API_KEY"
		}
	}

	/// Why `contents` can't be a ChatGPT login, worded for the user. Nil when it can.
	static func problem(with contents: String) -> String? {
		guard let parsed = try? JSONDecoder().decode(Contents.self, from: Data(contents.utf8)) else {
			return "Expected the contents of '~/.codex/auth.json', found something that isn't JSON"
		}
		guard let tokens = parsed.tokens else {
			if parsed.apiKey?.isEmpty == false {
				return "Expected a ChatGPT login in 'auth.json', found an API key, connect it as an API key instead"
			}
			return "Expected a ChatGPT login in 'auth.json', found no tokens, run 'codex login' first"
		}
		guard tokens.accessToken?.isEmpty == false, tokens.refreshToken?.isEmpty == false else {
			return "Expected an access and a refresh token in 'auth.json'"
		}
		return nil
	}
}
