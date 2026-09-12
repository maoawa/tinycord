//
//  AppSettings.swift
//  TinyCord Watch App
//

import SwiftUI
import Combine

public enum SubtitleDisplayMode: String, CaseIterable, Identifiable, Codable {
    case latestMessage = "latestMessage"
    case username = "username"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .latestMessage: return "Latest Message"
        case .username: return "@username"
        }
    }

    public var iconName: String {
        switch self {
        case .latestMessage: return "message.fill"
        case .username: return "at"
        }
    }
}

public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()

    public static let defaultQuickReplies: [String] = [
        "OK",
        "On my way!",
        "Can't talk right now",
        "Yes",
        "No",
        "Thanks!",
        "Sounds good",
        "Call you later",
        "Check Discord later"
    ]

    private let subtitleModeKey = "tinycord_conversation_subtitle_mode"
    private let legacyShowLatestMessageKey = "tinycord_show_latest_message_under_nickname"
    private let quickRepliesKey = "tinycord_quick_replies"

    @Published public var subtitleMode: SubtitleDisplayMode {
        didSet {
            UserDefaults.standard.set(subtitleMode.rawValue, forKey: subtitleModeKey)
        }
    }

    @Published public var quickReplies: [String] {
        didSet {
            UserDefaults.standard.set(quickReplies, forKey: quickRepliesKey)
        }
    }

    public var showLatestMessage: Bool {
        get { subtitleMode == .latestMessage }
        set { subtitleMode = newValue ? .latestMessage : .username }
    }

    public init() {
        if let saved = UserDefaults.standard.string(forKey: subtitleModeKey),
           let mode = SubtitleDisplayMode(rawValue: saved) {
            self.subtitleMode = mode
        } else if UserDefaults.standard.object(forKey: legacyShowLatestMessageKey) != nil {
            let legacyBool = UserDefaults.standard.bool(forKey: legacyShowLatestMessageKey)
            self.subtitleMode = legacyBool ? .latestMessage : .username
        } else {
            // Latest message is the default
            self.subtitleMode = .latestMessage
        }

        if let savedReplies = UserDefaults.standard.stringArray(forKey: quickRepliesKey), !savedReplies.isEmpty {
            self.quickReplies = savedReplies
        } else {
            self.quickReplies = Self.defaultQuickReplies
        }
    }
}
