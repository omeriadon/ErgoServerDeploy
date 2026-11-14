//
//  FakeCLI.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import Foundation

/// Shell scripts that stand in for `claude` and `codex`. They tell the stages apart by the input's fields,
/// log each stage they answer to `calls`, the last input each stage got in `input-<stage>`, and leave their arguments
/// and environment in `args` and `env`.
enum FakeCLI {
	/// What an argument about rain and wet ground gets at each stage
	static let answers = [
		"gate": #"{"kind":"argument","reason":""}"#,
		"breakdown": #"{"premises":["If it rains, the ground is wet","It rains"],"conclusion":"the ground is wet","claims":[{"meaning":"It rains","descriptor":"it rains"},{"meaning":"The ground is wet","descriptor":"the ground is wet"}]}"#,
		"formalize": #"{"premises":["X→Y","X"],"conclusion":"Y"}"#,
		"verify": #"{"matches":true,"differences":[]}"#,
	]

	static let english = "If it rains, the ground is wet. It rains, so the ground is wet."

	/// `steps` replaces what a stage does: shell that prints the whole result, or calls `answer` with the structured output
	static func claude(in scratch: Scratch, _ steps: [String: String] = [:]) throws -> String {
		try scratch.script("claude", #"""
		input=$(cat)
		\#(stage(in: scratch))
		answer() {
			printf '{"type":"result","is_error":false,"api_error_status":null,"result":"","structured_output":%s}\n' "$1"
		}
		case "$stage" in
		\#(cases(steps))
		esac
		"""#)
	}

	/// Writes its answer to the `-o` file like Codex. When there's an `auth.json`, it records the file's mode and contents,
	/// then rotates the tokens the way a refresh would.
	static func codex(in scratch: Scratch, _ steps: [String: String] = [:]) throws -> String {
		try scratch.script("codex", #"""
		file=""
		previous=""
		for argument in "$@"; do
			[ "$previous" = "-o" ] && file="$argument"
			previous="$argument"
		done
		input=$(cat)
		\#(stage(in: scratch))
		auth="$CODEX_HOME/auth.json"
		if [ -f "$auth" ]; then
			(stat -f %Lp "$auth" 2>/dev/null || stat -c %a "$auth") >> '\#(scratch.path("modes"))'
			cat "$auth" >> '\#(scratch.path("received"))'
			echo >> '\#(scratch.path("received"))'
			count=$(( $(cat '\#(scratch.path("count"))' 2>/dev/null || echo 0) + 1 ))
			echo "$count" > '\#(scratch.path("count"))'
			printf '{"tokens":{"access_token":"access-%s","refresh_token":"refresh-%s"}}' "$count" "$count" > "$auth"
		fi
		answer() {
			printf '%s' "$1" > "$file"
			echo '{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5}}'
		}
		case "$stage" in
		\#(cases(steps))
		esac
		"""#)
	}

	/// Writes its pid and its child's, then sleeps until it's killed
	static func sleeping(in scratch: Scratch) -> String {
		#"""
		echo $$ > '\#(scratch.path("pid"))'
		sleep 30 &
		echo $! > '\#(scratch.path("child"))'
		wait
		"""#
	}

	// MARK: - Pieces

	private static func stage(in scratch: Scratch) -> String {
		#"""
		case "$input" in
			*'"reading"'*) stage=verify ;;
			*'"grammarVersion"'*) stage=formalize ;;
			*'"maximumClaims"'*) stage=breakdown ;;
			*) stage=gate ;;
		esac
		echo "$stage" >> '\#(scratch.path("calls"))'
		printf '%s' "$input" > '\#(scratch.path("input-"))'"$stage"
		printf '%s\n' "$@" > '\#(scratch.path("args"))'
		env > '\#(scratch.path("env"))'
		"""#
	}

	private static func cases(_ steps: [String: String]) -> String {
		["gate", "breakdown", "formalize", "verify"].map { stage in
			"\t\(stage)) \(steps[stage] ?? "answer '\(answers[stage] ?? "")'") ;;"
		}.joined(separator: "\n")
	}
}
