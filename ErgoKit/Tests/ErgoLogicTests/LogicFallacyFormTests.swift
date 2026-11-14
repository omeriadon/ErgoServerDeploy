//
//  LogicFallacyFormTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoLogic
import Foundation
import Testing

struct LogicFallacyFormTests {
	/// The catalog stays in the app, next to this package
	static let catalog = URL(filePath: #filePath)
		.deletingLastPathComponent()
		.appending(path: "../../Sources/ErgoCatalog/Resources/fallacies.json")
		.standardizedFileURL

	private struct Catalog: Decodable {
		struct Fallacy: Decodable {
			let id: String
		}

		let fallacies: [Fallacy]
	}

	@Test(.enabled(if: FileManager.default.fileExists(atPath: catalog.path)))
	func everyFormIsInTheCatalog() throws {
		let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: Self.catalog))
		let ids = Set(catalog.fallacies.map(\.id))

		for id in LogicFallacyForm.all.map(\.fallacyID) + ["non-sequitur"] {
			#expect(ids.contains(id), "'\(id)' isn't in fallacies.json")
		}
	}
}
