//
//  UsageTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 10/11/2026.
//

import ErgoProtocol
import ErgoTranslation
import Foundation
import Testing

struct UsageTests {
	static let date = Date(timeIntervalSince1970: 1_794_268_800) // 2026-11-10 00:00 UTC

	@Test func aPriceIsMillionthsOfADollar() {
		#expect(UsagePrice(input: 0.2, output: 1.2).micros(inputTokens: 10000, outputTokens: 600) == 2720)
	}

	@Test func periodsAreUTC() {
		#expect(UsagePeriod.day(of: Self.date.addingTimeInterval(-1)) == "2026-11-09")
		#expect(UsagePeriod.day(of: Self.date) == "2026-11-10")
		#expect(UsagePeriod.month(of: Self.date) == "2026-11")
		#expect(UsagePeriod.week(of: Self.date) == "2026-W46")
		#expect(UsagePeriod.nextDay(after: Self.date.addingTimeInterval(5)) == Self.date.addingTimeInterval(86400))
	}

	@Test func anUnknownModeReadsAsNormal() throws {
		#expect(try JSONDecoder().decode(AskMode.self, from: Data(#""sing""#.utf8)) == .normal)
	}

	@Test func nothingIsHeldBackUntilPlansAreEnforced() {
		func status(_ plan: AccountPlan, enforced: Bool) -> UsageStatus {
			UsageStatus(plan: plan, plansEnforced: enforced, fractionUsed: 0, resets: Self.date, deepResearchLeft: 1, deepResearchPerWeek: 1, needsDeviceClaim: false)
		}
		#expect(status(.free, enforced: false).hasPlusFeatures)
		#expect(!status(.free, enforced: true).hasPlusFeatures)
		#expect(status(.plus, enforced: true).hasPlusFeatures)
	}

	@Test func theNewMessagesRoundTrip() throws {
		let edit = AskBoardEdit(change: .addCard(id: UUID(), english: "A claim.", near: nil))
		for message in [AskServerMessage.boardEdit(edit), .modeRequest(AskModeRequest(mode: .scout, reason: "Find the problems"))] {
			let data = try ErgoProtocol.encoder.encode(message)
			#expect(try ErgoProtocol.decoder.decode(AskServerMessage.self, from: data) == message)
		}
	}

	@Test func theBoardCountsTowardsTheLimit() {
		let text = String(repeating: "a", count: AskRequest.characterLimit)
		let board = AskBoard(title: "T", canEdit: true, statements: [], links: [], sources: [.init(id: UUID(), title: "", text: text)])
		#expect(AskRequest(id: UUID(), provider: .claude, messages: [AskRequestMessage(role: .user, text: "Hi")], board: board).problem != nil)
	}
}

struct TextPartsTests {
	@Test func shortTextIsOnePart() {
		#expect(TextParts.split("Just this.") == ["Just this."])
	}

	@Test func nothingIsLostAndEveryPartFits() {
		let sentence = String(repeating: "word ", count: 30) + "end."
		let text = (0 ..< 40).map { _ in sentence }.joined(separator: " ") + "\n\nA last paragraph."
		let parts = TextParts.split(text, characterLimit: 500)
		#expect(parts.count > 1)
		#expect(parts.allSatisfy { $0.count <= 500 })
		#expect(parts.joined(separator: " ").count(where: { $0 == "." }) == 41)
	}

	@Test func paragraphsStayTogetherWhenTheyFit() {
		#expect(TextParts.split("One.\n\nTwo.", characterLimit: 100) == ["One.\n\nTwo."])
		#expect(TextParts.split("First para.\n\nSecond para.", characterLimit: 12) == ["First para.", "Second para."])
	}

	@Test func aHugeSentenceIsStillCut() {
		let parts = TextParts.split(String(repeating: "a", count: 25), characterLimit: 10)
		#expect(parts.map(\.count) == [10, 10, 5])
	}
}
