//
//  TranslationEvent.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoLogic
import Foundation

/// One kind of model call, named like the stage it runs
public enum TranslationStep: String, Codable, Sendable, CaseIterable {
	case gate, breakdown, formalize, verify
}

/// What the pipeline is doing, sent to the app as it happens
public enum TranslationEvent: Codable, Hashable, Sendable {
	/// A model call began. `attempt` counts that step's calls from 1, and only goes past 1 for formalize and verify.
	case started(step: TranslationStep, attempt: Int)

	/// Breakdown finished. `descriptors` are sanitised, one per letter slot.
	case foundClaims(premises: [String], conclusion: String, descriptors: [String])

	/// A formalize attempt compiled. Not final: verify may still send it back.
	case drafted(entries: [LogicKeyboardEntry], attempt: Int)

	/// Formalize attempt `attempt` was rejected, by the compiler or by verify, and the next one starts with these problems
	case retrying(problems: [String], attempt: Int)
}
