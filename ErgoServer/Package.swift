// swift-tools-version: 6.2

import PackageDescription

let package = Package(
	name: "ErgoServer",
	platforms: [
		.macOS("27.3"),
	],
	dependencies: [
		.package(path: "../ErgoKit"),
		.package(url: "https://github.com/vapor/vapor.git", from: "4.122.0"),
		.package(url: "https://github.com/vapor/fluent.git", from: "4.13.0"),
		.package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.9.0"),
		.package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.14.0"),
		.package(url: "https://github.com/vapor/jwt.git", from: "5.2.0"),
		.package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
		.package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "1.0.0"),
		.package(url: "https://github.com/swift-server/async-http-client.git", from: "1.20.0"),
	],
	targets: [
		.executableTarget(
			name: "ErgoServer",
			dependencies: [
				.product(name: "ErgoLogic", package: "ErgoKit"),
				.product(name: "ErgoTranslation", package: "ErgoKit"),
				.product(name: "ErgoProtocol", package: "ErgoKit"),
				.product(name: "ErgoCatalog", package: "ErgoKit"),
				.product(name: "ErgoAsk", package: "ErgoKit"),
				.product(name: "Vapor", package: "vapor"),
				.product(name: "Fluent", package: "fluent"),
				.product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
				.product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
				.product(name: "JWT", package: "jwt"),
				.product(name: "Crypto", package: "swift-crypto"),
				.product(name: "Subprocess", package: "swift-subprocess"),
				.product(name: "AsyncHTTPClient", package: "async-http-client"),
			],
			resources: [
				.process("Prompts/Ask"),
				.process("Prompts/BoardAnalysis"),
				.process("Prompts/Gate"),
				.process("Prompts/Breakdown"),
				.process("Prompts/Formalize"),
				.process("Prompts/Verify"),
				.process("Prompts/Title"),
				.process("Legal/privacy-policy.md"),
				.process("Legal/terms.md"),
			]
		),
		.testTarget(
			name: "ErgoServerTests",
			dependencies: [
				"ErgoServer",
				.product(name: "ErgoLogic", package: "ErgoKit"),
				.product(name: "ErgoTranslation", package: "ErgoKit"),
				.product(name: "ErgoProtocol", package: "ErgoKit"),
				.product(name: "ErgoClient", package: "ErgoKit"),
				.product(name: "VaporTesting", package: "vapor"),
				.product(name: "JWT", package: "jwt"),
			],
			resources: [
				.copy("Fixtures"),
			]
		),
	],
	swiftLanguageModes: [.v6]
)
