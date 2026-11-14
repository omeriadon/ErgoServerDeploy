//
//  BoardAnalysisProtocolTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 8/11/2026.
//

import ErgoProtocol
import ErgoSync
import Foundation
import Testing

struct BoardAnalysisRequestTests {
	static let first = UUID()
	static let second = UUID()

	static func request(
		statements: [BoardAnalysisRequest.Statement] = [.init(id: first, english: "It rained."), .init(id: second, english: "The ground is wet.")],
		links: [BoardAnalysisRequest.Link] = [.init(id: UUID(), premise: first, conclusion: second)],
		sources: [BoardAnalysisRequest.Source] = []
	) -> BoardAnalysisRequest {
		BoardAnalysisRequest(run: UUID(), provider: .claude, statements: statements, links: links, sources: sources)
	}

	@Test func aGoodBoardCanRun() {
		#expect(Self.request().problem == nil)
		#expect(Self.request(statements: [], links: [], sources: [.init(id: UUID(), title: "Post", text: "Words")]).problem == nil)
	}

	@Test func nothingToAnalyseIsRefused() {
		#expect(Self.request(statements: [], links: [], sources: []).problem == "Expected a board with at least one statement or source")
	}

	@Test func aLinkNamingAMissingStatementIsRefused() {
		let links = [BoardAnalysisRequest.Link(id: UUID(), premise: Self.first, conclusion: UUID())]
		#expect(Self.request(links: links).problem != nil)
	}

	@Test func aDuplicateIDIsRefused() {
		let statements = [BoardAnalysisRequest.Statement(id: Self.first, english: "A"), .init(id: Self.first, english: "B")]
		#expect(Self.request(statements: statements, links: []).problem != nil)
		let source = BoardAnalysisRequest.Source(id: Self.first, title: "T", text: "Words")
		#expect(Self.request(sources: [source]).problem != nil)
	}

	@Test func overTheLimitIsRefused() {
		let text = String(repeating: "a", count: BoardAnalysisRequest.characterLimit)
		let source = BoardAnalysisRequest.Source(id: UUID(), title: "T", text: text)
		#expect(Self.request(statements: [], links: [], sources: [source]).problem == "Expected a board of at most 200000 characters, found \(text.count + 1)")
		#expect(Self.request(statements: [], links: [], sources: [.init(id: UUID(), title: "", text: text)]).problem == nil)
	}

	@Test func theRequestRoundTrips() throws {
		let request = Self.request(sources: [.init(id: UUID(), title: "T", text: "Words")])
		let data = try ErgoProtocol.encoder.encode(request)
		#expect(try ErgoProtocol.decoder.decode(BoardAnalysisRequest.self, from: data) == request)
	}

	@Test func theRouteIsUnderTheBoard() {
		#expect(ErgoProtocol.Path.boardAnalysis("ABC") == "v1/boards/ABC/analysis")
	}
}

struct BoardQuoteTests {
	@Test func caseDoesntMatter() {
		#expect(BoardQuote.isQuote("STRAW MAN", in: "That is a straw man."))
	}

	@Test func whitespaceRunsAreOne() {
		#expect(BoardQuote.isQuote("a  straw\n\tman", in: "That is a straw man."))
		#expect(BoardQuote.isQuote("a straw man", in: "That is a  straw \n man."))
		#expect(BoardQuote.isQuote("  straw man  ", in: "straw man"))
	}

	@Test func curlyAndStraightQuotesMatch() {
		#expect(BoardQuote.isQuote("it's \"fine\"", in: "Really, it’s “fine” now"))
		#expect(BoardQuote.isQuote("it’s “fine”", in: "Really, it's \"fine\" now"))
	}

	@Test func wordsThatArentThereArentQuotes() {
		#expect(!BoardQuote.isQuote("straw woman", in: "That is a straw man."))
		#expect(!BoardQuote.isQuote("   ", in: "That is a straw man."))
		#expect(!BoardQuote.isQuote("a long quote that is longer than the text", in: "short"))
	}

	@Test func theRangeIsInTheOriginalText() throws {
		let text = "Really,   it’s  “FINE”\nnow"
		let range = try #require(BoardQuote.range(of: "it's \"fine\"", in: text))
		#expect(text[range] == "it’s  “FINE”")

		let spaced = try #require(BoardQuote.range(of: "fine\" NOW", in: text))
		#expect(text[spaced] == "FINE”\nnow")
	}

	@Test func theRangeSkipsTheQuotesOwnPadding() throws {
		let text = "one two three"
		let range = try #require(BoardQuote.range(of: "  two ", in: text))
		#expect(text[range] == "two")
	}

	@Test func aQuoteWithEmojiKeepsItsRange() throws {
		let text = "Cheap 😀 stuff  is   best"
		let range = try #require(BoardQuote.range(of: "😀 stuff is", in: text))
		#expect(text[range] == "😀 stuff  is")
	}

	@Test func normalizingFoldsEverything() {
		#expect(BoardQuote.normalized("  It’s\n  “OK”  ") == "it's \"ok\"")
	}
}

struct BoardAnalysisShownTests {
	static let premiseID = UUID()
	static let otherID = UUID()
	static let conclusionID = UUID()
	static let firstLink = UUID()
	static let secondLink = UUID()
	static let textSource = UUID()
	static let linkSource = UUID()
	static let board = UUID()
	static let citation = LibraryCitation(category: "fallacies", id: "straw-man", name: "Straw man")

	static func snapshot(
		premise: String = "It rained.",
		other: String = "The sky was grey.",
		conclusion: String = "The ground is wet.",
		sourceText: String = "Everyone says it is a scam, so it is.",
		secondLinkExists: Bool = true
	) -> BoardAnalysisSnapshot {
		BoardAnalysisSnapshot(
			statements: [premiseID: premise, otherID: other, conclusionID: conclusion],
			links: [.init(id: firstLink, premise: premiseID, conclusion: conclusionID)]
				+ (secondLinkExists ? [.init(id: secondLink, premise: otherID, conclusion: conclusionID)] : []),
			sources: [.init(id: textSource, title: "Post", text: sourceText), .init(id: linkSource, title: "example.com", text: nil)]
		)
	}

	static func annotation(
		_ target: BoardAnalysisTarget,
		quote: String? = nil,
		assessment: BoardAnnotation.Assessment? = nil,
		basis: [UUID: String] = [:],
		run: UUID = UUID(),
		citation: LibraryCitation = citation
	) -> BoardAnnotation {
		BoardAnnotation(id: UUID(), board: board, run: run, target: target, citation: citation, quote: quote, markdown: "Because.", assessment: assessment, basis: basis)
	}

	static func written(_ annotation: BoardAnnotation, _ time: Int64 = 1000) -> WrittenAnnotation {
		WrittenAnnotation(annotation: annotation, stamp: SyncStamp(time: time, counter: 0, device: "server"))
	}

	static func shown(_ annotations: [BoardAnnotation], on snapshot: BoardAnalysisSnapshot = snapshot()) -> BoardAnalysisShown {
		BoardAnalysisShown(annotations.map { written($0) }, on: snapshot)
	}

	static let arrowBasis = [premiseID: "It rained.", otherID: "The sky was grey.", conclusionID: "The ground is wet."]

	@Test func aQuoteIsCurrentWhileItsStillInTheText() {
		let statement = Self.annotation(.statement(Self.premiseID), quote: "IT  rained")
		#expect(Self.shown([statement]).current == [statement])
		#expect(Self.shown([statement], on: Self.snapshot(premise: "It snowed.")).stale == [statement])
	}

	@Test func aTextSourceFollowsItsText() {
		let source = Self.annotation(.source(Self.textSource), quote: "everyone says")
		#expect(Self.shown([source]).current == [source])
		#expect(Self.shown([source], on: Self.snapshot(sourceText: "Some say it is.")).hasStale)
	}

	@Test func aLinkSourceFollowsItsTitle() {
		let source = Self.annotation(.source(Self.linkSource), quote: "anything", basis: [Self.linkSource: "example.com"])
		#expect(Self.shown([source]).current == [source])
		let renamed = BoardAnalysisSnapshot(statements: [:], links: [], sources: [.init(id: Self.linkSource, title: "other.com", text: nil)])
		#expect(Self.shown([source], on: renamed).stale == [source])
	}

	@Test func aSourceThatsGoneIsStale() {
		let source = Self.annotation(.source(UUID()), quote: "everyone says")
		#expect(Self.shown([source]).stale == [source])
	}

	@Test func anArrowQuoteIsCurrentFromEitherCard() {
		let run = UUID()
		let first = Self.annotation(.link(Self.firstLink), quote: "it rained", run: run)
		let second = Self.annotation(.link(Self.firstLink), quote: "ground is wet", run: run)
		#expect(Self.shown([first, second]).current.count == 2)
		#expect(Self.shown([first, second], on: Self.snapshot(premise: "Rain.")).current == [second])
	}

	@Test func aQuoteOnALinkThatsGoneIsStale() {
		let quote = Self.annotation(.link(Self.firstLink), quote: "it rained")
		let board = BoardAnalysisSnapshot(statements: Self.snapshot().statements, links: [], sources: [])
		#expect(Self.shown([quote], on: board).stale == [quote])
	}

	@Test func anAssessmentIsCurrentUntilACardChanges() {
		let arrow = Self.annotation(.link(Self.firstLink), assessment: .arrow(.weak), basis: Self.arrowBasis)
		let conclusion = Self.annotation(.statement(Self.conclusionID), assessment: .conclusion(.partlySupported), basis: Self.arrowBasis)
		#expect(Self.shown([arrow, conclusion]).current.count == 2)

		for changed in [Self.snapshot(premise: "It drizzled."), Self.snapshot(other: "Clear."), Self.snapshot(conclusion: "The ground is dry.")] {
			#expect(Self.shown([arrow, conclusion], on: changed).stale.count == 2)
		}
	}

	@Test func anAssessmentGoesStaleWhenAPremiseComesOrGoes() {
		let conclusion = Self.annotation(.statement(Self.conclusionID), assessment: .conclusion(.wellSupported), basis: Self.arrowBasis)
		#expect(Self.shown([conclusion], on: Self.snapshot(secondLinkExists: false)).stale == [conclusion])

		let fewer = [Self.premiseID: "It rained.", Self.conclusionID: "The ground is wet."]
		let judgedOnOne = Self.annotation(.statement(Self.conclusionID), assessment: .conclusion(.wellSupported), basis: fewer)
		#expect(Self.shown([judgedOnOne]).stale == [judgedOnOne])
		#expect(Self.shown([judgedOnOne], on: Self.snapshot(secondLinkExists: false)).current == [judgedOnOne])
	}

	@Test func anAssessmentOfAMissingTargetIsStale() {
		let arrow = Self.annotation(.link(UUID()), assessment: .arrow(.strong), basis: Self.arrowBasis)
		let conclusion = Self.annotation(.statement(Self.premiseID), assessment: .conclusion(.unsupported), basis: [Self.premiseID: "It rained."])
		#expect(Self.shown([arrow, conclusion]).stale.count == 2)
	}

	@Test func theNewestRunWins() {
		let old = Self.annotation(.statement(Self.premiseID), quote: "it rained", run: UUID())
		let new = Self.annotation(.statement(Self.premiseID), quote: "it rained", run: UUID())
		let shown = BoardAnalysisShown([Self.written(new, 2000), Self.written(old, 1000)], on: Self.snapshot())
		#expect(shown.current == [new])
	}

	@Test func anotherEntryOrKindOfReportKeepsItsOwnRun() {
		let other = LibraryCitation(category: "biases", id: "anchoring", name: "Anchoring")
		let old = Self.annotation(.statement(Self.premiseID), quote: "it rained", run: UUID())
		let new = Self.annotation(.statement(Self.premiseID), quote: "it rained", run: UUID(), citation: other)
		let assessed = Self.annotation(.statement(Self.conclusionID), assessment: .conclusion(.wellSupported), basis: Self.arrowBasis, run: UUID())
		let quoted = Self.annotation(.statement(Self.conclusionID), quote: "ground", run: UUID())
		let shown = BoardAnalysisShown([Self.written(old, 1000), Self.written(new, 2000), Self.written(assessed, 1000), Self.written(quoted, 3000)], on: Self.snapshot())
		#expect(Set(shown.current) == [old, new, assessed, quoted])
	}

	@Test func aNewestRunThatIsStaleDoesNotBringBackAnOlderOne() {
		let old = Self.annotation(.statement(Self.premiseID), quote: "it rained", run: UUID())
		let new = Self.annotation(.statement(Self.premiseID), quote: "it rained", run: UUID())
		let shown = BoardAnalysisShown([Self.written(old, 1000), Self.written(new, 2000)], on: Self.snapshot(premise: "Snow."))
		#expect(shown.current.isEmpty)
		#expect(shown.stale == [new])
	}

	@Test func nothingMeansNothingIsStale() {
		let shown = BoardAnalysisShown([], on: Self.snapshot())
		#expect(shown.current.isEmpty)
		#expect(!shown.hasStale)
	}

	@Test func aRunningStatusGoesStaleAndIsShownAsInterrupted() {
		let started = Date(timeIntervalSince1970: 1_000_000)
		let status = BoardAnalysisStatus(board: Self.board, run: UUID(), state: .running, started: started)
		#expect(status.shown(at: started.addingTimeInterval(60)) == .running)
		#expect(status.shown(at: started.addingTimeInterval(BoardAnalysisStatus.staleAfter + 1)) == .interrupted)

		let finished = BoardAnalysisStatus(board: Self.board, run: UUID(), state: .finished, started: started)
		#expect(finished.shown(at: started.addingTimeInterval(86400)) == .finished)
	}
}

struct BoardAnalysisCommentTests {
	@Test func aCommentIsTheFirstSentenceInPlainText() {
		let markdown = "This looks like a [**straw man**](ergo://library/fallacies/straw-man). It answers a weaker claim."
		#expect(BoardAnalysisComment.firstSentence(ofMarkdown: markdown) == "This looks like a straw man.")
	}

	@Test func anAbbreviationDoesntEndTheSentence() {
		#expect(BoardAnalysisComment.firstSentence(ofMarkdown: "Some cases, e.g. this one, fail. Others don't.") == "Some cases, e.g. this one, fail.")
	}

	@Test func onlyTheFirstParagraphCounts() {
		#expect(BoardAnalysisComment.firstSentence(ofMarkdown: "\n\nNo full stop here\n\nA second paragraph.") == "No full stop here")
	}

	@Test func aLongSentenceIsCut() {
		let comment = BoardAnalysisComment.firstSentence(ofMarkdown: String(repeating: "word ", count: 100))
		#expect(comment.count == 160)
		#expect(comment.hasSuffix("…"))
	}
}
