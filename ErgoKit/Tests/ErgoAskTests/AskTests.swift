//
//  AskTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 6/11/2026.
//

import ErgoAsk
import ErgoCatalog
import ErgoProtocol
import ErgoSync
import Foundation
import Testing

struct LibraryCatalogTests {
	@Test func theRealFilesLoad() throws {
		let catalog = try LibraryCatalog.load()
		for category in LibraryCatalog.categories {
			#expect(!catalog.list(category: category).isEmpty, "\(category)")
		}
		#expect(catalog.entries.allSatisfy { !$0.details.contains("\"image\"") })
	}

	@Test func searchPutsTheNameFirst() throws {
		let catalog = try LibraryCatalog.load()
		let found = catalog.search("straw man")
		#expect(found.first?.category == "fallacies")
		#expect(found.first?.name.lowercased().contains("straw") == true)
		#expect(catalog.search("   ").isEmpty)
	}

	@Test func searchKeepsToACategory() throws {
		let catalog = try LibraryCatalog.load()
		#expect(catalog.search("memory", category: "biases").allSatisfy { $0.category == "biases" })
	}
}

struct AskIntentTests {
	@Test func urlsRoundTrip() throws {
		let intents: [AskIntent] = [
			.openLibraryEntry(category: "fallacies", id: "straw-man"),
			.showLibraryList(category: "biases"),
			.openBookmarks,
			.openTab("board"),
			.askFollowUp("Is this valid & sound?"),
		]
		for intent in intents {
			#expect(try AskIntent(url: #require(intent.url)) == intent)
		}
	}

	@Test func otherLinksArentIntents() throws {
		#expect(try AskIntent(url: #require(URL(string: "https://example.com"))) == nil)
	}

	@Test func anIntentFromTheFutureIsKeptButUnknown() throws {
		let text = "ergo://intent/open-the-moon"
		#expect(try AskIntent(url: #require(URL(string: text))) == .unknown(text))

		let action = try JSONDecoder().decode(AskAction.self, from: Data(#"{"title": "Moon", "url": "ergo://intent/open-the-moon"}"#.utf8))
		#expect(action.intent == .unknown(text))
	}

	@Test func aMessageFromTheFutureIsUnknown() throws {
		let message = try JSONDecoder().decode(AskServerMessage.self, from: Data(#"{"type": "hologram", "colour": "blue"}"#.utf8))
		#expect(message == .unknown)
	}

	@Test func messagesRoundTrip() throws {
		let messages: [AskServerMessage] = [
			.text("Hi"),
			.tool(AskToolActivity(tool: "search_library", summary: "Searching")),
			.action(AskAction(title: "Open", intent: .openBookmarks)),
			.title("Straw man in the minimum wage debate"),
			.finished,
			.failed(ServiceError(code: .busy, message: "Busy")),
		]
		for message in messages {
			let data = try JSONEncoder().encode(message)
			#expect(try JSONDecoder().decode(AskServerMessage.self, from: data) == message)
		}
	}

	@Test func requestsAreChecked() {
		#expect(AskRequest(id: UUID(), provider: .claude, messages: []).problem != nil)
		#expect(AskRequest(id: UUID(), provider: .claude, messages: [.init(role: .assistant, text: "Hi")]).problem != nil)
		#expect(AskRequest(id: UUID(), provider: .claude, messages: [.init(role: .user, text: "Hi")]).problem == nil)
		#expect(AskRequest(id: UUID(), provider: .claude, messages: [.init(role: .user, text: String(repeating: "a", count: 200_001))]).problem != nil)
	}
}

actor Heard {
	var messages: [AskServerMessage] = []

	func record(_ message: AskServerMessage) {
		messages.append(message)
	}
}

struct AskToolServerTests {
	let entry = LibraryEntryText(
		category: "fallacies",
		id: "straw-man",
		name: "Straw man",
		aliases: ["scarecrow"],
		summary: "Answering a weaker version of the claim.",
		tags: ["relevance"],
		details: #"{"id":"straw-man"}"#
	)

	var server: AskToolServer<AskTools> {
		AskToolServer(tools: AskTools(catalog: LibraryCatalog(entries: [entry])))
	}

	private func send(_ json: String, heard: Heard = Heard()) async throws -> [String: JSONValue] {
		let reply = await server.respond(to: Data(json.utf8)) { await heard.record($0) }
		guard case let .object(object) = try JSONDecoder().decode(JSONValue.self, from: reply) else {
			Issue.record("Expected an object")
			return [:]
		}
		return object
	}

	/// The text of a tools/call result, and whether it's an error
	private func toolText(_ reply: [String: JSONValue]) -> (String, Bool)? {
		guard
			case let .object(result)? = reply["result"],
			case let .array(content)? = result["content"],
			case let .object(first)? = content.first,
			case let .string(text)? = first["text"],
			case let .bool(isError)? = result["isError"]
		else {
			return nil
		}
		return (text, isError)
	}

	@Test func initializeEchoesTheVersion() async throws {
		let reply = try await send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2030-01-01"}}"#)
		guard case let .object(result)? = reply["result"] else {
			Issue.record("Expected a result")
			return
		}
		#expect(result["protocolVersion"] == .string("2030-01-01"))
		#expect(reply["id"] == .number(1))
	}

	@Test func notificationsGetNoReply() async {
		let reply = await server.respond(to: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)) { _ in }
		#expect(reply.isEmpty)
	}

	@Test func listsEveryTool() async throws {
		let reply = try await send(#"{"jsonrpc":"2.0","id":"a","method":"tools/list"}"#)
		guard case let .object(result)? = reply["result"], case let .array(tools)? = result["tools"] else {
			Issue.record("Expected tools")
			return
		}
		#expect(tools.count == AskTools.names.count)
		#expect(reply["id"] == .string("a"))
	}

	@Test func searchReturnsALinkToCite() async throws {
		let heard = Heard()
		let reply = try await send(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search_library","arguments":{"query":"straw"}}}"#, heard: heard)
		let (text, isError) = try #require(toolText(reply))
		#expect(!isError)
		#expect(text.contains("[Straw man](ergo://intent/open-library-entry?category=fallacies&id=straw-man)"))
		#expect(await heard.messages == [.tool(AskToolActivity(tool: "search_library", summary: "Searching the library for 'straw'", record: "Searched the library for 'straw'"))])
	}

	@Test func readingAnEntryGivesAllOfIt() async throws {
		let reply = try await send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_library_entry","arguments":{"category":"fallacies","id":"straw-man"}}}"#)
		let (text, isError) = try #require(toolText(reply))
		#expect(!isError)
		let json = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
		guard case let .object(object) = json else {
			Issue.record("Expected an object")
			return
		}
		#expect(object["entry"] == .object(["id": .string("straw-man")]))
	}

	@Test func anInventedEntryIsAnErrorTheModelCanRead() async throws {
		let reply = try await send(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_library_entry","arguments":{"category":"fallacies","id":"made-up"}}}"#)
		let (text, isError) = try #require(toolText(reply))
		#expect(isError)
		#expect(text.contains("made-up"))
	}

	@Test func aSuggestedActionReachesTheApp() async throws {
		let heard = Heard()
		_ = try await send(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"suggest_action","arguments":{"title":"Open it","action":"open_library_entry","category":"fallacies","id":"straw-man"}}}"#, heard: heard)
		#expect(await heard.messages == [.action(AskAction(title: "Open it", intent: .openLibraryEntry(category: "fallacies", id: "straw-man")))])
	}

	@Test func aSuggestedFollowUpReachesTheApp() async throws {
		let heard = Heard()
		_ = try await send(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"suggest_action","arguments":{"title":"Ask more","action":"ask_follow_up","text":"Is it also circular?"}}}"#, heard: heard)
		#expect(await heard.messages == [.action(AskAction(title: "Ask more", intent: .askFollowUp("Is it also circular?")))])
	}

	@Test func aSuggestedFollowUpNeedsItsText() async throws {
		let heard = Heard()
		let reply = try await send(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"suggest_action","arguments":{"title":"Ask more","action":"ask_follow_up"}}}"#, heard: heard)
		#expect(try #require(toolText(reply)).1)
		#expect(await heard.messages.isEmpty)
	}

	@Test func aSuggestedActionForNothingIsRefused() async throws {
		let heard = Heard()
		let reply = try await send(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"suggest_action","arguments":{"title":"Open it","action":"open_library_entry","category":"fallacies","id":"made-up"}}}"#, heard: heard)
		#expect(try #require(toolText(reply)).1)
		#expect(await heard.messages.isEmpty)
	}

	@Test func unknownMethodsAreProtocolErrors() async throws {
		let reply = try await send(#"{"jsonrpc":"2.0","id":7,"method":"resources/list"}"#)
		#expect(reply["error"] != nil)
	}

	@Test func garbageIsAnError() async throws {
		let reply = try await send("not json")
		#expect(reply["error"] != nil)
	}
}

struct AskCLIStreamTests {
	@Test func claudeStreamsDeltasAndSeparatesBlocks() {
		var stream = ClaudeAskStream()
		let lines = [
			#"{"type":"system","subtype":"init"}"#,
			#"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text"}}}"#,
			#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hel"}}}"#,
			#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"lo"}}}"#,
			#"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"tool_use"}}}"#,
			#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{}"}}}"#,
			#"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text"}}}"#,
			#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Done"}}}"#,
			"some stderr",
			#"{"type":"result","is_error":false,"result":"Done"}"#,
		]
		let text = lines.compactMap { stream.feed($0) }.joined()
		#expect(text == "Hello\n\nDone")
		#expect(stream.resultLine != nil)
	}

	@Test func claudeFallsBackToTheResult() {
		var stream = ClaudeAskStream()
		#expect(stream.feed(#"{"type":"result","is_error":false,"result":"Whole answer"}"#) == "Whole answer")
	}

	@Test func codexGivesWholeMessages() {
		var stream = CodexAskStream()
		let lines = [
			#"{"type":"thread.started","thread_id":"1"}"#,
			#"{"type":"item.completed","item":{"type":"mcp_tool_call"}}"#,
			#"{"type":"item.completed","item":{"type":"agent_message","text":"First"}}"#,
			#"{"type":"item.completed","item":{"type":"agent_message","text":"Second"}}"#,
			#"{"type":"turn.completed","usage":{}}"#,
		]
		#expect(lines.compactMap { stream.feed($0) }.joined() == "First\n\nSecond")
		#expect(String(decoding: stream.output, as: UTF8.self).contains("turn.completed"))
	}
}

struct CodexAppServerSessionTests {
	private func sent(_ outputs: [CodexAppServerSession.Output]) -> [[String: Any]] {
		outputs.compactMap { output in
			guard case let .send(line) = output else { return nil }
			return try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
		}
	}

	@Test func startsAThreadThenATurnWithThePrompt() throws {
		var session = CodexAppServerSession(prompt: "The prompt", directory: "/work")
		let opening = try #require(JSONSerialization.jsonObject(with: Data(session.opening.utf8)) as? [String: Any])
		#expect(opening["method"] as? String == "initialize")

		let afterInitialize = sent(session.feed(#"{"id":1,"result":{"userAgent":"x"}}"#))
		#expect(afterInitialize.map { $0["method"] as? String } == ["initialized", "thread/start"])

		let afterThread = sent(session.feed(#"{"id":2,"result":{"thread":{"id":"t1","preview":""}}}"#))
		let turn = try #require(afterThread.first)
		#expect(turn["method"] as? String == "turn/start")
		let params = try #require(turn["params"] as? [String: Any])
		#expect(params["threadId"] as? String == "t1")
		#expect((params["input"] as? [[String: Any]])?.first?["text"] as? String == "The prompt")
	}

	@Test func streamsDeltasAndSeparatesMessages() {
		var session = CodexAppServerSession(prompt: "p", directory: "/w")
		var outputs = session.feed(#"{"method":"item/agentMessage/delta","params":{"threadId":"t","turnId":"u","itemId":"a","delta":"one "}}"#)
		outputs += session.feed(#"{"method":"item/agentMessage/delta","params":{"threadId":"t","turnId":"u","itemId":"a","delta":"two"}}"#)
		outputs += session.feed(#"{"method":"item/agentMessage/delta","params":{"threadId":"t","turnId":"u","itemId":"b","delta":"three"}}"#)
		#expect(outputs == [.text("one "), .text("two"), .text("\n\nthree")])
	}

	@Test func retriesItHandlesItselfAreIgnored() {
		var session = CodexAppServerSession(prompt: "p", directory: "/w")
		#expect(session.feed(#"{"method":"error","params":{"error":{"message":"Reconnecting... 2/5"}}}"#).isEmpty)
		#expect(session.feed("not json").isEmpty)
	}

	@Test func aTurnEndsOneWayOrTheOther() {
		var session = CodexAppServerSession(prompt: "p", directory: "/w")
		#expect(session.feed(#"{"method":"turn/completed","params":{"turn":{"status":"completed","error":null}}}"#) == [.finished])
		#expect(session.feed(#"{"method":"turn/completed","params":{"turn":{"status":"failed","error":{"message":"Usage limit"}}}}"#) == [.failed("Usage limit")])
	}

	@Test func aRefusedRequestFails() {
		var session = CodexAppServerSession(prompt: "p", directory: "/w")
		#expect(session.feed(#"{"id":2,"error":{"code":-32600,"message":"No"}}"#) == [.failed("No")])
	}
}
