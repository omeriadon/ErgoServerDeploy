//
//  BoardAnalysisToolsTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 8/11/2026.
//

import ErgoAsk
import ErgoCatalog
import ErgoProtocol
import ErgoSync
import Foundation
import Testing

struct BoardAnalysisToolsTests {
	static let rain = UUID()
	static let wet = UUID()
	static let arrow = UUID()
	static let lonely = UUID()
	static let source = UUID()

	static let catalog = LibraryCatalog(entries: [
		LibraryEntryText(category: "fallacies", id: "straw-man", name: "Straw man", aliases: [], summary: "Answering a weaker claim.", tags: [], details: #"{"id":"straw-man"}"#),
		LibraryEntryText(category: "concepts", id: "cogency", name: "Cogency", aliases: [], summary: "Strong with true premises.", tags: [], details: #"{"id":"cogency"}"#),
		LibraryEntryText(category: "symbols", id: "negation", name: "Negation", aliases: [], summary: "Not.", tags: [], details: #"{"id":"negation"}"#),
	])

	static let request = BoardAnalysisRequest(
		run: UUID(),
		provider: .claude,
		statements: [
			.init(id: rain, english: "It rained all night."),
			.init(id: wet, english: "The ground is wet."),
			.init(id: lonely, english: "Nobody is home."),
		],
		links: [.init(id: arrow, premise: rain, conclusion: wet)],
		sources: [.init(id: source, title: "Post", text: "Critics say the plan is a “total scam”, so ignore them.")]
	)

	/// Tools that have read the straw man and cogency entries, as a run that did its homework has
	static func tools(read: [String] = ["straw-man"]) throws -> BoardAnalysisTools {
		let tools = BoardAnalysisTools(request: request, catalog: catalog)
		for id in read {
			let category = id == "cogency" ? "concepts" : "fallacies"
			_ = try tools.reply(to: "get_library_entry", arguments: ["category": .string(category), "id": .string(id)])
		}
		return tools
	}

	static func annotate(_ overrides: [String: JSONValue] = [:]) -> [String: JSONValue] {
		var arguments: [String: JSONValue] = [
			"target_kind": "statement",
			"target_id": .string(rain.uuidString),
			"category": "fallacies",
			"id": "straw-man",
			"quote": "rained all",
			"markdown": "This looks like a **straw man**.",
		]
		arguments.merge(overrides) { $1 }
		return arguments
	}

	/// What the model reads when a call is refused
	static func refusal(_ tools: BoardAnalysisTools, _ name: String, _ arguments: [String: JSONValue]) -> String? {
		do {
			_ = try tools.reply(to: name, arguments: arguments)
			return nil
		} catch {
			return error.message
		}
	}

	static func report(_ reply: AskToolReply<BoardAnalysisEvent>) -> BoardAnalysisReport? {
		if case let .report(report)? = reply.event {
			return report
		}
		return nil
	}

	// MARK: - Accepting

	@Test func aGoodAnnotationIsReported() throws {
		let reply = try Self.tools().reply(to: "annotate", arguments: Self.annotate())
		let report = try #require(Self.report(reply))
		#expect(report.target == .statement(Self.rain))
		#expect(report.citation == LibraryCitation(category: "fallacies", id: "straw-man", name: "Straw man"))
		#expect(report.quote == "rained all")
		#expect(report.assessment == nil)
	}

	@Test func aQuoteOnASourceKeepsItsCurlyQuotesAndNeedsOnlyItsText() throws {
		let arguments = Self.annotate(["target_kind": "source", "target_id": .string(Self.source.uuidString), "quote": "a \"TOTAL scam\""])
		let report = try #require(Self.report(Self.tools().reply(to: "annotate", arguments: arguments)))
		#expect(report.target == .source(Self.source))
		#expect(report.annotation(board: UUID(), in: Self.request).basis == [Self.source: "Post"])
	}

	@Test func aLinkQuoteCanBeFromEitherCard() throws {
		for quote in ["rained all night", "ground is wet"] {
			let arguments = Self.annotate(["target_kind": "link", "target_id": .string(Self.arrow.uuidString), "quote": .string(quote)])
			#expect(try Self.report(Self.tools().reply(to: "annotate", arguments: arguments))?.target == .link(Self.arrow))
		}
		let other = Self.annotate(["target_kind": "link", "target_id": .string(Self.arrow.uuidString), "quote": "nobody is home"])
		#expect(try Self.refusal(Self.tools(), "annotate", other) != nil)
	}

	@Test func anArrowAssessmentIsReportedWithItsBasis() throws {
		let arguments: [String: JSONValue] = ["link_id": .string(Self.arrow.uuidString), "strength": "strong", "category": "concepts", "id": "cogency", "markdown": "Fairly good."]
		let report = try #require(Self.report(Self.tools(read: ["cogency"]).reply(to: "assess_arrow", arguments: arguments)))
		#expect(report.target == .link(Self.arrow))
		#expect(report.assessment == .arrow(.strong))
		#expect(report.quote == nil)

		let annotation = report.annotation(board: UUID(), in: Self.request)
		#expect(annotation.run == Self.request.run)
		#expect(annotation.basis == [Self.rain: "It rained all night.", Self.wet: "The ground is wet."])
	}

	@Test func aConclusionAssessmentIsReported() throws {
		let arguments: [String: JSONValue] = ["statement_id": .string(Self.wet.uuidString), "support": "wellSupported", "category": "concepts", "id": "cogency", "markdown": "Yes."]
		let report = try #require(Self.report(Self.tools(read: ["cogency"]).reply(to: "assess_conclusion", arguments: arguments)))
		#expect(report.target == .statement(Self.wet))
		#expect(report.assessment == .conclusion(.wellSupported))
	}

	@Test func readingToolsStillWorkAndNothingIsReported() throws {
		let tools = try Self.tools(read: [])
		let reply = try tools.reply(to: "search_library", arguments: ["query": "straw"])
		#expect(reply.event == nil)
		#expect(reply.text.contains("straw-man"))
		#expect(tools.event(running: "get_library_entry", arguments: ["category": "fallacies", "id": "straw-man"]) == .tool(AskToolActivity(tool: "get_library_entry", summary: "Reading Straw man", record: "Read Straw man")))
	}

	@Test func theToolListIsReadingPlusReporting() {
		let names = BoardAnalysisTools(request: Self.request, catalog: Self.catalog).definitions.compactMap { definition -> String? in
			guard case let .object(object) = definition, case let .string(name)? = object["name"] else { return nil }
			return name
		}
		#expect(names == BoardAnalysisTools.names)
		#expect(!names.contains("suggest_action"))
	}

	// MARK: - Refusing

	@Test func anUnknownTargetIsRefused() throws {
		let tools = try Self.tools()
		#expect(Self.refusal(tools, "annotate", Self.annotate(["target_id": .string(UUID().uuidString)])) != nil)
		#expect(Self.refusal(tools, "annotate", Self.annotate(["target_id": "not an id"])) != nil)
		#expect(Self.refusal(tools, "annotate", Self.annotate(["target_kind": "board"])) != nil)
		// A statement's id isn't a link's
		#expect(Self.refusal(tools, "annotate", Self.annotate(["target_kind": "link"])) != nil)
		#expect(Self.refusal(tools, "assess_arrow", ["link_id": .string(UUID().uuidString), "strength": "weak", "category": "fallacies", "id": "straw-man", "markdown": "m"]) != nil)
		#expect(Self.refusal(tools, "assess_conclusion", ["statement_id": .string(UUID().uuidString), "support": "unsupported", "category": "fallacies", "id": "straw-man", "markdown": "m"]) != nil)
	}

	@Test func anUnknownEntryIsRefused() throws {
		let tools = try Self.tools()
		#expect(Self.refusal(tools, "annotate", Self.annotate(["id": "made-up"])) != nil)
		#expect(Self.refusal(tools, "annotate", Self.annotate(["category": "philosophers", "id": "straw-man"])) != nil)
	}

	@Test func anEntryNotReadThisRunIsRefused() throws {
		let tools = try Self.tools(read: [])
		let message = try #require(Self.refusal(tools, "annotate", Self.annotate()))
		#expect(message == "Read Straw man with get_library_entry before citing it")

		// Searching for it doesn't count as reading it, and neither does a failed read
		_ = try tools.reply(to: "search_library", arguments: ["query": "straw"])
		_ = try? tools.reply(to: "get_library_entry", arguments: ["category": "fallacies", "id": "made-up"])
		#expect(Self.refusal(tools, "annotate", Self.annotate()) != nil)

		_ = try tools.reply(to: "get_library_entry", arguments: ["category": "fallacies", "id": "straw-man"])
		#expect(Self.refusal(tools, "annotate", Self.annotate()) == nil)
	}

	@Test func theSymbolsCategoryIsRefusedEvenWhenRead() throws {
		let tools = try Self.tools()
		_ = try tools.reply(to: "get_library_entry", arguments: ["category": "symbols", "id": "negation"])
		#expect(Self.refusal(tools, "annotate", Self.annotate(["category": "symbols", "id": "negation"])) != nil)
	}

	@Test func aQuoteNotInTheTargetIsRefused() throws {
		let tools = try Self.tools()
		#expect(Self.refusal(tools, "annotate", Self.annotate(["quote": "snowed"])) != nil)
		#expect(Self.refusal(tools, "annotate", Self.annotate(["quote": "ground is wet"])) != nil, "That's the other statement's")
		#expect(Self.refusal(tools, "annotate", Self.annotate(["quote": "ra"])) != nil, "Under three characters")
		#expect(Self.refusal(tools, "annotate", Self.annotate(["quote": "   "])) != nil)
		#expect(Self.refusal(tools, "annotate", Self.annotate(["quote": ""])) != nil)
	}

	@Test func aDuplicateIsRefused() throws {
		let tools = try Self.tools(read: ["straw-man", "cogency"])
		#expect(Self.refusal(tools, "annotate", Self.annotate()) == nil)
		#expect(Self.refusal(tools, "annotate", Self.annotate(["quote": "night"])) != nil, "Same target and entry")
		#expect(Self.refusal(tools, "annotate", Self.annotate(["category": "concepts", "id": "cogency"])) == nil, "Another entry")

		let arrow: [String: JSONValue] = ["link_id": .string(Self.arrow.uuidString), "strength": "weak", "category": "concepts", "id": "cogency", "markdown": "m"]
		#expect(Self.refusal(tools, "assess_arrow", arrow) == nil)
		#expect(Self.refusal(tools, "assess_arrow", arrow.merging(["category": "fallacies", "id": "straw-man"]) { $1 }) != nil, "Any entry, still the second")

		let conclusion: [String: JSONValue] = ["statement_id": .string(Self.wet.uuidString), "support": "unsupported", "category": "concepts", "id": "cogency", "markdown": "m"]
		#expect(Self.refusal(tools, "assess_conclusion", conclusion) == nil)
		#expect(Self.refusal(tools, "assess_conclusion", conclusion) != nil)
	}

	@Test func theLimitStopsReports() throws {
		let tools = try Self.tools()
		let texts = (0 ..< BoardAnalysisTools.reportLimit).map { "text number \($0)" }
		let statements = texts.map { BoardAnalysisRequest.Statement(id: UUID(), english: $0) }
		let many = BoardAnalysisTools(request: BoardAnalysisRequest(run: UUID(), provider: .claude, statements: statements, links: [], sources: []), catalog: Self.catalog)
		_ = try many.reply(to: "get_library_entry", arguments: ["category": "fallacies", "id": "straw-man"])
		for statement in statements {
			let arguments = Self.annotate(["target_id": .string(statement.id.uuidString), "quote": .string(statement.english)])
			#expect(Self.refusal(many, "annotate", arguments) == nil)
		}
		let last = Self.annotate(["target_id": .string(statements[0].id.uuidString), "category": "fallacies", "id": "straw-man", "quote": .string(statements[0].english)])
		#expect(Self.refusal(many, "annotate", last)?.contains("at most 150") == true)
		_ = tools
	}

	@Test func aLaterPartHasWhatsLeftOfTheBudget() throws {
		let tools = BoardAnalysisTools(request: Self.request, catalog: Self.catalog, reportBudget: 1)
		_ = try tools.reply(to: "get_library_entry", arguments: ["category": "fallacies", "id": "straw-man"])
		#expect(Self.refusal(tools, "annotate", Self.annotate()) == nil)
		let another = Self.annotate(["target_id": .string(Self.wet.uuidString), "quote": "ground is wet"])
		#expect(Self.refusal(tools, "annotate", another)?.contains("at most 1 reports") == true)
	}

	@Test func aLaterPartOnlyTakesReportsOnItsPart() throws {
		let text = (0 ..< 8).map { "Paragraph \($0) makes a claim about the plan." }.joined(separator: "\n\n")
		let long = BoardAnalysisRequest(
			run: UUID(),
			provider: .claude,
			statements: Self.request.statements,
			links: Self.request.links,
			sources: [.init(id: Self.source, title: "Post", text: text)]
		)
		let passes = long.passes(partLimit: 120)
		let last = try #require(passes.last)
		#expect(passes.count > 1)
		let tools = BoardAnalysisTools(request: last.request, catalog: Self.catalog)
		_ = try tools.reply(to: "get_library_entry", arguments: ["category": "fallacies", "id": "straw-man"])

		let here = Self.annotate(["target_kind": "source", "target_id": .string(Self.source.uuidString), "quote": "Paragraph 7 makes"])
		#expect(Self.refusal(tools, "annotate", here) == nil)
		let earlier = Self.annotate(["target_kind": "source", "target_id": .string(Self.source.uuidString), "quote": "Paragraph 0 makes"])
		#expect(Self.refusal(tools, "annotate", earlier)?.contains("isn't in the text") == true, "Quotes are checked against this part")
		#expect(Self.refusal(tools, "annotate", Self.annotate()) != nil, "Cards were the first part's")
		let arrow: [String: JSONValue] = ["link_id": .string(Self.arrow.uuidString), "strength": "weak", "category": "fallacies", "id": "straw-man", "markdown": "m"]
		#expect(Self.refusal(tools, "assess_arrow", arrow) != nil, "Arrows were assessed in the first part")
	}

	@Test func aConclusionNeedsPremises() throws {
		let tools = try Self.tools()
		for statement in [Self.rain, Self.lonely] {
			let arguments: [String: JSONValue] = ["statement_id": .string(statement.uuidString), "support": "unsupported", "category": "fallacies", "id": "straw-man", "markdown": "m"]
			#expect(Self.refusal(tools, "assess_conclusion", arguments) != nil)
		}
	}

	@Test func badEnumsAreRefused() throws {
		let tools = try Self.tools()
		#expect(Self.refusal(tools, "assess_arrow", ["link_id": .string(Self.arrow.uuidString), "strength": "mighty", "category": "fallacies", "id": "straw-man", "markdown": "m"]) != nil)
		#expect(Self.refusal(tools, "assess_conclusion", ["statement_id": .string(Self.wet.uuidString), "support": "strong", "category": "fallacies", "id": "straw-man", "markdown": "m"]) != nil)
	}

	@Test func emptyOrHugeMarkdownIsRefused() throws {
		let tools = try Self.tools()
		#expect(Self.refusal(tools, "annotate", Self.annotate(["markdown": ""])) != nil)
		#expect(Self.refusal(tools, "annotate", Self.annotate(["markdown": " \n "])) != nil)
		#expect(Self.refusal(tools, "annotate", Self.annotate(["markdown": .string(String(repeating: "a", count: BoardAnalysisTools.markdownLimit + 1))])) != nil)
		#expect(Self.refusal(tools, "annotate", Self.annotate(["markdown": .string(String(repeating: "a", count: BoardAnalysisTools.markdownLimit))])) == nil)
	}

	@Test func aRefusedReportDoesntCountAgainstTheLimitOrAsADuplicate() throws {
		let tools = try Self.tools()
		#expect(Self.refusal(tools, "annotate", Self.annotate(["quote": "snowed"])) != nil)
		#expect(Self.refusal(tools, "annotate", Self.annotate()) == nil)
	}

	// MARK: - Ask

	@Test func anAskRunCantCallAReportTool() throws {
		let tools = AskTools(catalog: Self.catalog)
		for name in ["annotate", "assess_arrow", "assess_conclusion"] {
			do {
				_ = try tools.call(name, arguments: Self.annotate())
				Issue.record("Expected \(name) to be refused")
			} catch {
				#expect(error.message == "No tool is called '\(name)'")
			}
		}
		let listed = AskTools.definitions.compactMap { definition -> String? in
			guard case let .object(object) = definition, case let .string(name)? = object["name"] else { return nil }
			return name
		}
		#expect(listed == AskTools.names)
	}

	@Test func theServerSendsReportsToWhoeverStartedTheRun() async throws {
		actor Heard {
			var events: [BoardAnalysisEvent] = []

			func record(_ event: BoardAnalysisEvent) {
				events.append(event)
			}
		}
		let heard = Heard()
		let server = try AskToolServer(tools: Self.tools())
		let call = JSONValue.object(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": .object(["name": "annotate", "arguments": .object(Self.annotate())])])
		let reply = try await server.respond(to: JSONEncoder().encode(call)) { await heard.record($0) }
		#expect(String(decoding: reply, as: UTF8.self).contains("\"isError\":false"))
		let events = await heard.events
		#expect(events.count == 1)
		#expect(Self.report(AskToolReply(text: "", event: events.first))?.quote == "rained all")
	}
}
