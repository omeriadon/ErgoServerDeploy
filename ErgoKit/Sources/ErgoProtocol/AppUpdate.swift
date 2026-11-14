//
//  AppUpdate.swift
//  ErgoKit
//
//  Created by Adon Omeri on 10/11/2026.
//

import Foundation

/// How much the server wants this app updated
public enum AppUpdate: String, Sendable, Hashable {
	/// Still answered, but a newer version is out and this one's protocol will be dropped
	case recommended

	/// Turned away with `outdatedApp`: nothing that needs the server works until it's updated
	case required
}
