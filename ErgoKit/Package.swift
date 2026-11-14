// swift-tools-version: 6.2

import PackageDescription

/// What the app, the server and the evals share: the logic checker, the translation contract,
/// the sync merge rules, the wire protocol, a client for it, the library and what Ask does with it
let package = Package(
	name: "ErgoKit",
	platforms: [
		.iOS("27.0"),
		.macOS("27.0"),
	],
	products: [
		.library(name: "ErgoLogic", targets: ["ErgoLogic"]),
		.library(name: "ErgoTranslation", targets: ["ErgoTranslation"]),
		.library(name: "ErgoSync", targets: ["ErgoSync"]),
		.library(name: "ErgoProtocol", targets: ["ErgoProtocol"]),
		.library(name: "ErgoClient", targets: ["ErgoClient"]),
		.library(name: "ErgoCatalog", targets: ["ErgoCatalog"]),
		.library(name: "ErgoAsk", targets: ["ErgoAsk"]),
		.library(name: "ErgoMarkdown", targets: ["ErgoMarkdown"]),
		.library(name: "ErgoShare", targets: ["ErgoShare"]),
	],
	targets: [
		.target(name: "ErgoLogic"),
		.target(name: "ErgoTranslation", dependencies: ["ErgoLogic"]),
		.target(name: "ErgoSync"),
		.target(name: "ErgoProtocol", dependencies: ["ErgoTranslation", "ErgoSync"]),
		.target(name: "ErgoClient", dependencies: ["ErgoProtocol"]),
		.target(name: "ErgoCatalog", resources: [.process("Resources")]),
		.target(name: "ErgoAsk", dependencies: ["ErgoCatalog", "ErgoProtocol", "ErgoSync"]),
		.target(name: "ErgoMarkdown"),
		.target(name: "ErgoShare"),

		.testTarget(name: "ErgoLogicTests", dependencies: ["ErgoLogic"]),
		.testTarget(name: "ErgoTranslationTests", dependencies: ["ErgoLogic", "ErgoTranslation"]),
		.testTarget(name: "ErgoSyncTests", dependencies: ["ErgoSync"]),
		.testTarget(name: "ErgoProtocolTests", dependencies: ["ErgoLogic", "ErgoTranslation", "ErgoSync", "ErgoProtocol"]),
		.testTarget(name: "ErgoClientTests", dependencies: ["ErgoSync", "ErgoProtocol", "ErgoClient"]),
		.testTarget(name: "ErgoAskTests", dependencies: ["ErgoAsk", "ErgoCatalog", "ErgoProtocol", "ErgoSync"]),
		.testTarget(name: "ErgoMarkdownTests", dependencies: ["ErgoMarkdown"]),
		.testTarget(name: "ErgoShareTests", dependencies: ["ErgoShare"]),
		// Talks to a running server, only when ERGO_LIVE_SERVER is set. See LiveServerTests.
		.testTarget(name: "ErgoLiveTests", dependencies: ["ErgoSync", "ErgoProtocol", "ErgoClient"]),
	],
	swiftLanguageModes: [.v6]
)
