//
//  ThemeManager.swift
//  TinyCord Watch App
//

import SwiftUI
import Combine

public enum AppTheme: String, CaseIterable, Identifiable {
    case system = "system"
    case purple = "purple"
    case blurple = "blurple"
    case green = "green"
    case pink = "pink"
    case orange = "orange"
    case red = "red"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "Blue (Default)"
        case .purple: return "Purple"
        case .blurple: return "Blurple"
        case .green: return "Green"
        case .pink: return "Pink"
        case .orange: return "Orange"
        case .red: return "Red"
        }
    }

    public var color: Color {
        switch self {
        case .system: return Color.blue
        case .purple: return Color.purple
        case .blurple: return Color(red: 0.345, green: 0.396, blue: 0.949)
        case .green: return Color(red: 0.224, green: 0.737, blue: 0.392)
        case .pink: return Color.pink
        case .orange: return Color.orange
        case .red: return Color.red
        }
    }
}

public final class ThemeManager: ObservableObject {
    public static let shared = ThemeManager()

    private let key = "tinycord_selected_theme"
    private let themeButtonsKey = "tinycord_theme_action_buttons"

    @Published public var currentTheme: AppTheme {
        didSet {
            UserDefaults.standard.set(currentTheme.rawValue, forKey: key)
        }
    }

    @Published public var themeActionButtons: Bool {
        didSet {
            UserDefaults.standard.set(themeActionButtons, forKey: themeButtonsKey)
        }
    }

    public init() {
        if let saved = UserDefaults.standard.string(forKey: key),
           let theme = AppTheme(rawValue: saved) {
            self.currentTheme = theme
        } else {
            self.currentTheme = .system
        }

        self.themeActionButtons = UserDefaults.standard.bool(forKey: themeButtonsKey)
    }

    public var color: Color {
        currentTheme.color
    }

    /// Button tint is independent of the accent used for titles and messages.
    public var actionButtonColor: Color {
        themeActionButtons ? color : Color(white: 0.25)
    }

    public func setTheme(_ theme: AppTheme) {
        currentTheme = theme
    }
}
