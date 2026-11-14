//
//  BoardAnalysisPartsTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 14/11/2026.
//

import ErgoProtocol
import ErgoSync
import Foundation
import Testing

struct BoardAnalysisPassTests {
	static let card = UUID()
	static let other = UUID()
	static let long = UUID()
	static let short = UUID()

	static func request(sources: [BoardAnalysisRequest.Source]) -> BoardAnalysisRequest {
		BoardAnalysisRequest(
			run: UUID(),
			provider: .claude,
			statements: [.init(id: card, english: "It rained."), .init(id: other, english: "The ground is wet.")],
			links: [.init(id: UUID(), premise: card, conclusion: other)],
			sources: sources,
			instructions: "Be brief."
		)
	}

	static let longText = (0 ..< 30).map { "Paragraph \($0) of a long article, with a claim in it." }.joined(separator: "\n\n")

	@Test func aBoardThatFitsIsOnePassOfItself() {
		let request = Self.request(sources: [.init(id: Self.short, title: "Note", text: "Short.")])
		let passes = request.passes()
		#expect(passes.count == 1)
		#expect(passes[0].request == request)
		#expect(passes[0].isFirst)
		#expect(passes[0].parts.isEmpty)
	}

	@Test func aLongSourceIsReadInParts() {
		let request = Self.request(sources: [
			.init(id: Self.long, title: "Article", text: Self.longText),
			.init(id: Self.short, title: "Note", text: "Short."),
		])
		let passes = request.passes(partLimit: 400)
		#expect(passes.count > 1)
		#expect(passes.map(\.number) == Array(1 ... passes.count))
		#expect(passes.allSatisfy { $0.count == passes.count })

		let first = passes[0]
		#expect(first.request.statements == request.statements)
		#expect(first.request.links == request.links)
		#expect(first.request.sources.map(\.id) == [Self.long, Self.short])
		#expect(first.request.sources[1].text == "Short.")

		for pass in passes.dropFirst() {
			#expect(pass.request.statements.isEmpty, "Cards are only in the first pass")
			#expect(pass.request.links.isEmpty)
			#expect(pass.request.sources.map(\.id) == [Self.long])
			#expect(pass.request.problem == nil)
		}

		let parts = passes.compactMap { $0.request.sources.first { $0.id == Self.long } }
		#expect(BoardQuote.normalized(parts.map(\.text).joined(separator: " ")) == BoardQuote.normalized(Self.longText), "Every word, in order")
		#expect(parts.allSatisfy { $0.text.count <= 400 })
		#expect(parts.allSatisfy { BoardQuote.isQuote($0.text, in: Self.longText) }, "A quote from any part is in the whole text")
		#expect(parts.allSatisfy { $0.title == "Article" }, "Titles are left alone, since link sources stay current by them")
		#expect(passes.allSatisfy { $0.parts == [Self.long: passes.count] })
		#expect(passes.allSatisfy { $0.request.run == request.run && $0.request.instructions == request.instructions })
	}

	@Test func aQuoteInAPartIsInTheWholeText() throws {
		let request = Self.request(sources: [.init(id: Self.long, title: "Article", text: Self.longText)])
		let last = try #require(request.passes(partLimit: 400).last?.request.sources.first)
		#expect(BoardQuote.isQuote("Paragraph 29 of a long article", in: last.text))
		#expect(BoardQuote.isQuote("Paragraph 29 of a long article", in: Self.longText))
		#expect(!BoardQuote.isQuote("Paragraph 0 of a long article", in: last.text), "Quotes are checked against the part")
	}
}

struct BoardAnalysisHeartbeatTests {
	static let board = UUID()
	static let started = Date(timeIntervalSince1970: 1_000_000)

	@Test func aHeartbeatKeepsALongRunGoing() {
		let late = Self.started.addingTimeInterval(BoardAnalysisStatus.staleAfter + 60)
		let beating = BoardAnalysisStatus(board: Self.board, run: UUID(), state: .running, started: Self.started, heartbeat: late.addingTimeInterval(-60))
		#expect(beating.shown(at: late) == .running)
		#expect(beating.shown(at: late.addingTimeInterval(BoardAnalysisStatus.staleAfter)) == .interrupted)
	}

	@Test func aStatusWithoutAHeartbeatStillDecodes() throws {
		let old = Data("""
		{"board":"\(Self.board.uuidString)","run":"\(UUID().uuidString)","state":"running","started":"2026-11-08T00:00:00Z"}
		""".utf8)
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		let status = try decoder.decode(BoardAnalysisStatus.self, from: old)
		#expect(status.heartbeat == nil)
		#expect(status.state == .running)
	}

	@Test func noHeartbeatIsLeftOut() throws {
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		let status = BoardAnalysisStatus(board: Self.board, run: UUID(), state: .running, started: Self.started)
		let json = try #require(String(data: encoder.encode(status), encoding: .utf8))
		#expect(!json.contains("heartbeat"), "What an older server wrote and what this writes without one are the same")

		let beating = BoardAnalysisStatus(board: Self.board, run: UUID(), state: .running, started: Self.started, heartbeat: Self.started)
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		#expect(try decoder.decode(BoardAnalysisStatus.self, from: encoder.encode(beating)) == beating)
	}
}
