//
//  MarkdownDocument.swift
//  ErgoKit
//
//  Created by Adon Omeri on 6/11/2026.
//

import Foundation

/// Markdown as blocks for a view to lay out. Foundation does the parsing, including of text that's still arriving,
/// and each block's text is an `AttributedString` that `Text` shows with its bold, italics, code and links.
public struct MarkdownDocument: Sendable, Hashable {
	public indirect enum Block: Sendable, Hashable {
		case heading(level: Int, text: AttributedString)
		case paragraph(AttributedString)
		case code(language: String?, text: String)
		case quote([Block])
		case list(ordered: Bool, items: [[Block]])
		case table(header: [AttributedString], rows: [[AttributedString]])
		case rule

		/// Maths on its own line. It's text marked with `MarkdownMathAttribute`, like maths inside a line.
		case math(AttributedString)
	}

	public let blocks: [Block]

	public init(_ markdown: String) {
		let math = MarkdownMathExtraction(markdown)
		let options = AttributedString.MarkdownParsingOptions(
			allowsExtendedAttributes: true,
			interpretedSyntax: .full,
			failurePolicy: .returnPartiallyParsedIfPossible
		)
		guard let parsed = try? AttributedString(markdown: math.markdown, options: options) else {
			blocks = markdown.isEmpty ? [] : [.paragraph(AttributedString(markdown))]
			return
		}
		blocks = Self.blocks(in: Node.tree(of: parsed).children, math: math)
	}

	// MARK: - Tree

	/// A block as Foundation sees it. Every run of text names all the blocks it's inside, outermost last.
	private final class Node {
		let kind: PresentationIntent.Kind?
		let identity: Int
		var children: [Node] = []
		var text = AttributedString()

		init(kind: PresentationIntent.Kind?, identity: Int) {
			self.kind = kind
			self.identity = identity
		}

		/// Quotes and lists inside one another further than this are read as one paragraph at this level. No screen
		/// could show them, and every level is a level of the stack for whatever walks the blocks.
		static let maximumDepth = 40

		/// The paragraph that holds what was nested too far
		static let flattened = -2

		static func tree(of parsed: AttributedString) -> Node {
			let root = Node(kind: nil, identity: -1)
			for run in parsed.runs {
				var node = root
				for (depth, component) in (run.presentationIntent?.components ?? []).reversed().enumerated() {
					guard depth < maximumDepth else {
						if let last = node.children.last, last.identity == flattened {
							node = last
						} else {
							let child = Node(kind: .paragraph, identity: flattened)
							node.children.append(child)
							node = child
						}
						break
					}
					if let last = node.children.last, last.identity == component.identity {
						node = last
					} else {
						let child = Node(kind: component.kind, identity: component.identity)
						node.children.append(child)
						node = child
					}
				}
				var text = AttributedString(parsed[run.range])
				text.presentationIntent = nil
				node.text += text
			}
			return root
		}
	}

	private static func blocks(in nodes: [Node], math: MarkdownMathExtraction) -> [Block] {
		nodes.compactMap { block($0, math: math) }
	}

	private static func block(_ node: Node, math: MarkdownMathExtraction) -> Block? {
		guard let kind = node.kind else { return nil }
		switch kind {
			case let .header(level):
				return .heading(level: level, text: math.restored(node.text))
			case .paragraph:
				if let display = math.display(in: node.text) {
					return .math(display)
				}
				return .paragraph(math.restored(node.text))
			case let .codeBlock(language):
				var code = String(node.text.characters)
				if code.hasSuffix("\n") {
					code.removeLast()
				}
				return .code(language: language, text: code)
			case .blockQuote:
				return .quote(blocks(in: node.children, math: math))
			case .orderedList:
				return .list(ordered: true, items: node.children.map { blocks(in: $0.children, math: math) })
			case .unorderedList:
				return .list(ordered: false, items: node.children.map { blocks(in: $0.children, math: math) })
			case .thematicBreak:
				return .rule
			case .table:
				return table(node, math: math)
			default:
				return nil
		}
	}

	private static func table(_ node: Node, math: MarkdownMathExtraction) -> Block {
		var header: [AttributedString] = []
		var rows: [[AttributedString]] = []
		for row in node.children {
			let cells = row.children.map { math.restored($0.text) }
			if case .tableHeaderRow = row.kind {
				header = cells
			} else {
				rows.append(cells)
			}
		}
		return .table(header: header, rows: rows)
	}
}
