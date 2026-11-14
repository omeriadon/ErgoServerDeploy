//
//  SharingClientTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 7/11/2026.
//

@testable import ErgoClient
import ErgoProtocol
import Foundation
import Testing

/// One method per sharing route, against a stand-in server inside URLSession
struct SharingClientTests {
	static let board = "6F1C2E9A-3B4D-4E5F-8A9B-0C1D2E3F4A5B"
	static let member = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
	let client = ErgoClient(server: SyncClientTests.server, token: SharingStub.token, session: SharingStub.session)

	@Test func creatingAnInviteSendsTheBodyAndDecodesTheLink() async throws {
		let invite = try await client.createBoardInvite(board: Self.board, CreateBoardInvite(role: .viewer, title: "Rain", name: "Ada"))
		#expect(invite.url.absoluteString == "https://ergo.example.com/join/abc")
		#expect(invite.role == .viewer)
	}

	@Test func theRoutesThatAnswerNothing() async throws {
		try await client.revokeBoardInvites(board: Self.board)
		try await client.updateBoardMember(board: Self.board, member: Self.member, role: .viewer)
		try await client.removeBoardMember(board: Self.board, member: Self.member)
		try await client.stopSharingBoard(board: Self.board)
		try await client.registerPushDevice(token: "ab12")
		try await client.unregisterPushDevice()
	}

	@Test func reportingSendsTheTrimmedReason() async throws {
		try await client.reportBoard(board: Self.board, reason: "  Abuse \n")
	}

	@Test func reportingWithNoReasonNeverLeaves() async {
		await #expect(throws: ServiceError.self) {
			try await client.reportBoard(board: Self.board, reason: "  ")
		}
	}

	@Test func analysisStartsWithTheRequestAndStopsWithoutOne() async throws {
		let request = BoardAnalysisRequest(run: UUID(), provider: .claude, statements: [.init(id: UUID(), english: "It rained.")], links: [], sources: [])
		try await client.startBoardAnalysis(board: Self.board, request)
		try await client.stopBoardAnalysis(board: Self.board)
	}

	@Test func acceptingSendsTheTokenInTheBody() async throws {
		let joined = try await client.acceptBoardInvite(token: "abc", name: "Sam")
		#expect(joined == JoinedBoard(board: Self.board, role: .editor))
	}

	/// The stub refuses a preview that carries a token, so this passing means none went out
	@Test func previewingSendsNoBearerToken() async throws {
		let preview = try await client.previewBoardInvite(token: "abc")
		#expect(preview.ownerName == "Ada")

		let request = try client.request("POST", ErgoProtocol.Path.invitePreview, authorized: false, body: BoardInviteToken(token: "abc"))
		#expect(request.value(forHTTPHeaderField: "Authorization") == nil)
		#expect(request.value(forHTTPHeaderField: ErgoProtocol.versionHeader) == String(ErgoProtocol.version))
	}

	@Test func anExpiredLinkThrowsTheServersError() async {
		await #expect(throws: SharingStub.expired) {
			try await client.acceptBoardInvite(token: "expired", name: "Sam")
		}
	}
}

// MARK: - Stub

final class SharingStub: URLProtocol {
	static let token = "signed-in"
	static let expired = ServiceError(code: .invalidRequest, message: "Expected an invite that's still open, found one that expired or was revoked")

	static var session: URLSession {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [SharingStub.self]
		return URLSession(configuration: configuration)
	}

	override class func canInit(with _: URLRequest) -> Bool {
		true
	}

	override class func canonicalRequest(for request: URLRequest) -> URLRequest {
		request
	}

	override func startLoading() {
		let (status, body) = Self.reply(to: request)
		let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
		client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
		client?.urlProtocol(self, didLoad: body)
		client?.urlProtocolDidFinishLoading(self)
	}

	override func stopLoading() {}

	static func reply(to request: URLRequest) -> (Int, Data) {
		let board = SharingClientTests.board
		let member = SharingClientTests.member.uuidString
		let authorization = request.value(forHTTPHeaderField: "Authorization")
		let body = request.httpBodyStream.map(StubServer.read) ?? request.httpBody ?? Data()
		let path = request.url?.path() ?? ""

		if path == "/v1/invites/preview" {
			guard request.httpMethod == "POST", authorization == nil, (try? ErgoProtocol.decoder.decode(BoardInviteToken.self, from: body)) == BoardInviteToken(token: "abc") else { return (400, Data()) }
			return (200, StubServer.json(BoardInvitePreview(board: board, title: "Rain", ownerName: "Ada", role: .editor, memberCount: 2)))
		}

		guard authorization == "Bearer \(token)" else { return (401, Data()) }
		switch (request.httpMethod, path) {
			case ("POST", "/v1/boards/\(board)/invites"):
				guard let create = try? ErgoProtocol.decoder.decode(CreateBoardInvite.self, from: body), create.title == "Rain" else { return (400, Data()) }
				return (200, StubServer.json(BoardInvite(url: URL(string: "https://ergo.example.com/join/abc")!, role: create.role, expires: StubServer.now)))
			case ("DELETE", "/v1/boards/\(board)/invites"),
			     ("DELETE", "/v1/boards/\(board)/members/\(member)"),
			     ("DELETE", "/v1/boards/\(board)/share"),
			     ("DELETE", "/v1/push/device"):
				return (204, Data())
			case ("POST", "/v1/boards/\(board)/report"):
				return (try? ErgoProtocol.decoder.decode(ReportBoard.self, from: body)) == ReportBoard(reason: "Abuse") ? (204, Data()) : (400, Data())
			case ("POST", "/v1/boards/\(board)/analysis"):
				return (try? ErgoProtocol.decoder.decode(BoardAnalysisRequest.self, from: body))?.problem == nil ? (202, Data()) : (400, Data())
			case ("DELETE", "/v1/boards/\(board)/analysis"):
				return (204, Data())
			case ("POST", "/v1/boards/\(board)/members/\(member)"):
				return (try? ErgoProtocol.decoder.decode(UpdateBoardMember.self, from: body)) == UpdateBoardMember(role: .viewer) ? (204, Data()) : (400, Data())
			case ("PUT", "/v1/push/device"):
				return (try? ErgoProtocol.decoder.decode(PushDevice.self, from: body)) == PushDevice(token: "ab12") ? (204, Data()) : (400, Data())
			case ("POST", "/v1/invites/accept"):
				guard let accept = try? ErgoProtocol.decoder.decode(AcceptBoardInvite.self, from: body) else { return (400, Data()) }
				return accept.token == "abc" ? (200, StubServer.json(JoinedBoard(board: board, role: .editor))) : (400, StubServer.json(expired))
			default:
				return (404, Data())
		}
	}
}
