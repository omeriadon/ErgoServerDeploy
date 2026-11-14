//
//  SyncedSetting.swift
//  ErgoKit
//
//  Created by Adon Omeri on 5/11/2026.
//

import Foundation

/// The settings that follow the user to their other devices, as setting record ids. The app maps them to Defaults keys.
///
/// A setting left out stays on the device, which is right for anything about where this screen is
/// or where the server is. Never rename a case: it's the record id on the server.
public enum SyncedSetting: String, Codable, Sendable, CaseIterable, Hashable {
	case logicLetters
	case ditherEnabled
	case translationProvider
	case hapticsEnabled
	case itemOfTheDayCategories
	case agentInstructions
}
