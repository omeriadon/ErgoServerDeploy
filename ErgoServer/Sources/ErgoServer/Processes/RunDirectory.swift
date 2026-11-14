//
//  RunDirectory.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import Foundation
import Logging

/// A fresh, private directory for one CLI call: `home/` stands in for the user's home, `work/` is where it runs.
/// Nothing in it outlives the call.
struct RunDirectory: Sendable {
	let root: URL

	/// For what goes wrong with the directory itself, which has no account to speak of
	private static let log = Logger(label: "ergo.runs")

	var home: URL {
		root.appending(path: "home", directoryHint: .isDirectory)
	}

	var work: URL {
		root.appending(path: "work", directoryHint: .isDirectory)
	}

	var temporary: URL {
		home.appending(path: "tmp", directoryHint: .isDirectory)
	}

	/// Makes one, hands it to `body`, and removes it afterwards however `body` ends
	static func with<T>(in parent: URL, _ body: (RunDirectory) async throws -> T) async throws -> T {
		let run = try make(in: parent)
		defer { run.remove() }
		return try await body(run)
	}

	/// The parent can be passed through but not listed, so the runner user can reach the run it's handed without seeing the others
	static func make(in parent: URL) throws -> RunDirectory {
		let files = FileManager.default
		try files.createDirectory(at: parent, withIntermediateDirectories: true)
		try files.setAttributes([.posixPermissions: 0o711], ofItemAtPath: parent.path)

		let run = RunDirectory(root: parent.appending(path: UUID().uuidString, directoryHint: .isDirectory))
		// The server enters `work` for a CLI before the prefix switches users, after the run was handed over, so the
		// way there can be passed through. What's secret is in `home`.
		for (directory, permissions) in [(run.root, 0o711), (run.home, 0o700), (run.temporary, 0o700), (run.work, 0o711)] {
			try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: permissions])
		}
		return run
	}

	/// Written `0600`, since some of these are secrets
	func write(_ text: String, to file: URL) throws {
		try FileManager.default.createDirectory(
			at: file.deletingLastPathComponent(),
			withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o700]
		)
		guard FileManager.default.createFile(atPath: file.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
			throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
		}
	}

	func read(_ file: URL) -> String? {
		(try? Data(contentsOf: file)).map { String(decoding: $0, as: UTF8.self) }
	}

	func remove() {
		do {
			try FileManager.default.removeItem(at: root)
		} catch where !FileManager.default.fileExists(atPath: root.path) {
			// Already gone
		} catch {
			// What's left may hold a credential
			Self.log.warning("Couldn't remove a run directory", metadata: ["error": "\(String(describing: type(of: error)))"])
		}
	}

	// MARK: - Handing over

	/// Gives everything inside to the runner user, so a CLI running as that user can use it
	func handOver(to owner: ProcessRunner.Owner) throws {
		try chown(root.path, to: owner, contentsFirst: true)
	}

	/// Takes it back afterwards, so the server can read what the CLI left and delete it
	func takeBack() {
		do {
			try chown(root.path, to: ProcessRunner.Owner(user: getuid(), group: getgid()), contentsFirst: false)
		} catch {
			// Without it the server may not be able to read the answer, or delete the directory
			Self.log.warning("Couldn't take a run directory back from the runner user", metadata: ["error": "\(String(describing: type(of: error)))"])
		}
	}

	/// The server can only list a directory it owns, so handing over does the contents before the directory, and
	/// taking back the directory before the contents. A CLI's symlink is changed itself and never followed.
	private func chown(_ path: String, to owner: ProcessRunner.Owner, contentsFirst: Bool) throws {
		let files = FileManager.default

		if !contentsFirst {
			try changeOwner(of: path, to: owner)
		}
		if try files.attributesOfItem(atPath: path)[.type] as? FileAttributeType == .typeDirectory {
			for name in try files.contentsOfDirectory(atPath: path) {
				try chown("\(path)/\(name)", to: owner, contentsFirst: contentsFirst)
			}
		}
		if contentsFirst {
			try changeOwner(of: path, to: owner)
		}
	}

	private func changeOwner(of path: String, to owner: ProcessRunner.Owner) throws {
		guard lchown(path, owner.user, owner.group) == 0 else {
			throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
		}
	}
}
