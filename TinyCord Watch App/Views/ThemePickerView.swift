//
//  ThemePickerView.swift
//  TinyCord Watch App
//

import SwiftUI

struct ThemePickerView: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        List {
            Section(header: Text("Colors")) {
                ForEach(AppTheme.allCases) { theme in
                    Button {
                        themeManager.setTheme(theme)
                    } label: {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(theme.color)
                                .frame(width: 14, height: 14)

                            Text(theme.displayName)
                                .font(.system(size: 13))

                            Spacer()

                            if themeManager.currentTheme == theme {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(theme.color)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Section(header: Text("Icons & Buttons"), footer: Text("When off, all buttons and icons stay neutral watchOS glass.")) {
                Toggle("Themed Icons & Buttons", isOn: $themeManager.themeActionButtons)
                    .font(.system(size: 12))
            }
        }
        .navigationTitle {
            Text("Theme")
                .foregroundStyle(themeManager.color)
                .fontWeight(.semibold)
        }
    }
}
