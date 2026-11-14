//
//  LaTeX.swift
//  Ergo
//
//  Created by Adon Omeri on 8/11/2026.
//

import Foundation

/// LaTeX as real characters, for the kind of maths an argument needs: connectives, quantifiers, sets, Greek, sub and
/// superscripts. Being text, it flows with the words around it, and selecting and copying it just works. It doesn't
/// typeset: a fraction comes out as `a/b`, on one line. A command it doesn't know stays as written.
public enum LaTeX {
	public struct Run: Sendable, Hashable {
		public var text: String

		/// 0 on the line, 1 raised, -1 lowered
		public var script: Int

		public init(_ text: String, script: Int = 0) {
			self.text = text
			self.script = script
		}
	}

	public static func runs(_ source: String) -> [Run] {
		var parser = Parser(source)
		let runs = parser.parse(script: 0)
		return merged(runs).filter { !$0.text.isEmpty }
	}

	/// The same, as an `AttributedString` a view can style
	public static func attributed(_ source: String) -> AttributedString {
		var text = AttributedString()
		for run in runs(source) {
			var piece = AttributedString(run.text)
			piece[MarkdownMathAttribute.self] = run.script
			text += piece
		}
		return text
	}

	static func merged(_ runs: [Run]) -> [Run] {
		var merged: [Run] = []
		for run in runs {
			if merged.last?.script == run.script {
				merged[merged.count - 1].text += run.text
			} else {
				merged.append(run)
			}
		}
		// Spacing around operators can pile up where two meet, or at the very ends
		return merged.enumerated().map { index, run in
			var text = run.text
			while let range = text.range(of: "  ") {
				text.replaceSubrange(range, with: " ")
			}
			if index == 0, text.hasPrefix(" ") {
				text.removeFirst()
			}
			if index == merged.count - 1, text.hasSuffix(" ") {
				text.removeLast()
			}
			return Run(text, script: run.script)
		}
	}

	// MARK: - Symbols

	/// Written with a space either side
	static let spaced: Set<Character> = Set("→←↔⇒⇐⇔∧∨⊕⊢⊨∴∵≡≠≈≤≥=<>∈∉⊂⊃⊆⊇∪∩+−×÷·|↦")

	static let symbols: [String: String] = [
		// Logic
		"to": "→", "rightarrow": "→", "implies": "⇒", "Rightarrow": "⇒", "supset": "⊃", "gets": "←", "leftarrow": "←",
		"Leftarrow": "⇐", "leftrightarrow": "↔", "Leftrightarrow": "⇔", "iff": "⇔", "mapsto": "↦",
		"land": "∧", "wedge": "∧", "lor": "∨", "vee": "∨", "lnot": "¬", "neg": "¬", "oplus": "⊕", "veebar": "⊻",
		"forall": "∀", "exists": "∃", "nexists": "∄", "therefore": "∴", "because": "∵", "top": "⊤", "bot": "⊥",
		"vdash": "⊢", "dashv": "⊣", "models": "⊨", "vDash": "⊨", "nvdash": "⊬", "nvDash": "⊭", "Box": "□", "square": "□", "Diamond": "◇", "lozenge": "◊",
		"equiv": "≡", "qed": "∎", "blacksquare": "∎",
		// Relations and operators
		"neq": "≠", "ne": "≠", "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "approx": "≈", "sim": "∼", "cong": "≅",
		"times": "×", "div": "÷", "cdot": "·", "pm": "±", "mp": "∓", "ast": "∗", "circ": "∘", "bullet": "•", "cdots": "⋯", "ldots": "…", "dots": "…",
		"infty": "∞", "partial": "∂", "nabla": "∇", "sum": "∑", "prod": "∏", "int": "∫", "prime": "′", "mid": "|", "parallel": "∥", "perp": "⟂",
		// Sets
		"in": "∈", "notin": "∉", "ni": "∋", "subset": "⊂", "subseteq": "⊆", "supseteq": "⊇", "cup": "∪", "cap": "∩",
		"emptyset": "∅", "varnothing": "∅", "setminus": "∖", "bigcup": "⋃", "bigcap": "⋂", "bigwedge": "⋀", "bigvee": "⋁",
		// Brackets
		"langle": "⟨", "rangle": "⟩", "lceil": "⌈", "rceil": "⌉", "lfloor": "⌊", "rfloor": "⌋", "lbrace": "{", "rbrace": "}",
		// Greek
		"alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ",
		"iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π", "rho": "ρ", "sigma": "σ", "tau": "τ", "upsilon": "υ",
		"phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
		"Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
	]

	/// What only changes how something looks, which plain text can't show anyway
	static let styles: Set<String> = ["mathbf", "mathit", "mathsf", "mathtt", "mathcal", "mathbb", "mathfrak", "boldsymbol", "bm", "displaystyle", "textstyle"]

	/// Their argument is words, so its spaces are real
	static let textCommands: Set<String> = ["text", "textbf", "textit", "textrm", "texttt", "mathrm", "operatorname", "mbox"]

	static let spaces: [String: String] = [",": " ", ";": " ", ":": " ", ">": " ", "!": "", " ": " ", "quad": "  ", "qquad": "  ", "enspace": " "]

	/// Only there to size or arrange what's next to them
	static let ignored: Set<String> = ["left", "right", "big", "Big", "bigg", "Bigg", "limits", "nolimits", "hline"]

	// MARK: - Parsing

	struct Parser {
		/// Groups and arguments inside one another further than this stay as written, since each is a level of the stack
		static let maximumDepth = 48

		let characters: [Character]
		var index = 0
		private var depth = 0

		init(_ source: String) {
			characters = Array(source)
		}

		var current: Character? {
			index < characters.count ? characters[index] : nil
		}

		/// Up to the end, or the `}` of the group this was called for
		mutating func parse(script: Int) -> [Run] {
			var runs: [Run] = []
			while let character = current {
				switch character {
					case "}":
						return runs
					case "{":
						runs += group(script: script)
					case "\\":
						index += 1
						runs += command(script: script)
					case "^":
						index += 1
						runs += argument(script: script + 1 > 1 ? script : script + 1)
					case "_":
						index += 1
						runs += argument(script: script - 1 < -1 ? script : script - 1)
					case "~":
						index += 1
						runs.append(Run(" ", script: script))
					case "&":
						index += 1
					case "\n", "\r", " ", "\t":
						// Spaces mean nothing in LaTeX's maths, operators get their own
						index += 1
					case ",":
						index += 1
						runs.append(Run(", ", script: script))
					default:
						index += 1
						runs.append(Run(LaTeX.written(character), script: script))
				}
			}
			return runs
		}

		private mutating func group(script: Int) -> [Run] {
			depth += 1
			defer { depth -= 1 }
			guard depth <= Self.maximumDepth else {
				return [Run("{" + rawGroup() + "}", script: script)]
			}

			index += 1
			let runs = parse(script: script)
			if current == "}" {
				index += 1
			}
			return runs
		}

		/// What a command or a script applies to: a group, a command, or one character
		private mutating func argument(script: Int) -> [Run] {
			skipSpaces()
			depth += 1
			defer { depth -= 1 }
			guard depth <= Self.maximumDepth else { return [] }

			switch current {
				case "{":
					return group(script: script)
				case "\\":
					index += 1
					return command(script: script)
				case let character?:
					index += 1
					return [Run(LaTeX.written(character), script: script)]
				case nil:
					return []
			}
		}

		private mutating func skipSpaces() {
			while let character = current, character.isWhitespace {
				index += 1
			}
		}

		private mutating func rawGroup() -> String {
			skipSpaces()
			guard current == "{" else { return "" }
			index += 1
			var depth = 1
			var text = ""
			while let character = current {
				index += 1
				if character == "{" {
					depth += 1
				} else if character == "}" {
					depth -= 1
					if depth == 0 {
						break
					}
				}
				text.append(character)
			}
			return text
		}

		private mutating func command(script: Int) -> [Run] {
			guard let first = current else { return [Run("\\", script: script)] }

			// A single symbol: \{ \% \, and so on
			guard first.isLetter else {
				index += 1
				if first == "\\" {
					return [Run("\n", script: script)]
				}
				if let space = LaTeX.spaces[String(first)] {
					return [Run(space, script: script)]
				}
				return [Run(String(first), script: script)]
			}

			var name = ""
			while let character = current, character.isLetter {
				name.append(character)
				index += 1
			}

			if let symbol = LaTeX.symbols[name], let character = symbol.first {
				return [Run(LaTeX.written(character), script: script)]
			}
			if let space = LaTeX.spaces[name] {
				return [Run(space, script: script)]
			}
			if LaTeX.ignored.contains(name) {
				// The bracket that \left and \right size is still wanted, but a "." says there's none
				if current == "." {
					index += 1
				}
				return []
			}
			if LaTeX.styles.contains(name) {
				return argument(script: script)
			}
			if LaTeX.textCommands.contains(name) {
				return [Run(rawGroup(), script: script)]
			}

			switch name {
				case "begin", "end":
					_ = rawGroup()
					return []
				case "frac", "dfrac", "tfrac":
					let top = argument(script: script)
					let bottom = argument(script: script)
					return LaTeX.bracketed(top, script: script) + [Run("/", script: script)] + LaTeX.bracketed(bottom, script: script)
				case "sqrt":
					return [Run("√", script: script)] + LaTeX.bracketed(argument(script: script), script: script)
				case "overline", "bar", "hat", "tilde", "vec", "dot", "underline", "widehat", "widetilde":
					return argument(script: script)
				default:
					return [Run("\\" + name, script: script)]
			}
		}
	}

	static func written(_ character: Character) -> String {
		spaced.contains(character) ? " \(character) " : String(character)
	}

	/// Only what wouldn't read right without them
	static func bracketed(_ runs: [Run], script: Int) -> [Run] {
		runs.reduce(0) { $0 + $1.text.count } > 1 ? [Run("(", script: script)] + runs + [Run(")", script: script)] : runs
	}
}
