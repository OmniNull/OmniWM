// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

enum WorkspaceBarWindowContext {
    case tiled
    case floating
}

enum WorkspaceBarHiddenIndicatorStyle: Equatable {
    case appHidden
    case partiallyHidden
}

enum WorkspaceBarIconOpacity {
    static func standard(
        isFocused: Bool,
        isInFocusedWorkspace: Bool,
        configured: Double?
    ) -> Double {
        if isFocused { return 1 }
        if let configured { return configured }
        return isInFocusedWorkspace ? 0.4 : 0.5
    }

    static func scratchpad(isFocused: Bool, configured: Double?) -> Double {
        if isFocused { return 1 }
        return configured ?? 0.82
    }
}

struct WorkspaceBarWindowPresentation {
    let window: WorkspaceBarWindowItem
    let context: WorkspaceBarWindowContext
    let isFocused: Bool
    let isInFocusedWorkspace: Bool
    let inactiveIconOpacity: Double?

    init(
        window: WorkspaceBarWindowItem,
        context: WorkspaceBarWindowContext,
        isFocused: Bool,
        isInFocusedWorkspace: Bool,
        inactiveIconOpacity: Double? = nil
    ) {
        self.window = window
        self.context = context
        self.isFocused = isFocused
        self.isInFocusedWorkspace = isInFocusedWorkspace
        self.inactiveIconOpacity = inactiveIconOpacity
    }

    var hiddenIndicatorStyle: WorkspaceBarHiddenIndicatorStyle? {
        if window.isAppHidden {
            return .appHidden
        }
        if window.hasHiddenWindows {
            return .partiallyHidden
        }
        return nil
    }

    var appliesHiddenTint: Bool {
        window.isAppHidden
    }

    var iconOpacity: Double {
        if window.isAppHidden {
            return 0.9
        }
        return WorkspaceBarIconOpacity.standard(
            isFocused: isFocused,
            isInFocusedWorkspace: isInFocusedWorkspace,
            configured: inactiveIconOpacity
        )
    }

    var accessibilityLabel: String {
        switch (context, window.windowCount > 1) {
        case (.tiled, false):
            return String(localized: "\(window.appName) window")
        case (.tiled, true):
            return String(localized: "\(window.appName), \(window.windowCount) windows")
        case (.floating, false):
            return String(localized: "\(window.appName) floating window")
        case (.floating, true):
            return String(localized: "\(window.appName), \(window.windowCount) floating windows")
        }
    }

    var accessibilityValue: String {
        var values: [String] = []
        if isFocused {
            values.append(String(localized: "Focused"))
        }
        if window.isAppHidden {
            values.append(window.windowCount > 1
                ? String(localized: "All \(window.windowCount) windows hidden")
                : String(localized: "App hidden"))
        } else if window.hasHiddenWindows {
            values.append(String(localized: "\(window.hiddenWindowCount) of \(window.windowCount) windows hidden"))
        }
        return values.joined(separator: ", ")
    }

    var accessibilityHint: String {
        if window.windowCount > 1 {
            return String(localized: "Opens the window list")
        }
        return window.isAppHidden
            ? String(localized: "Unhides the app and focuses this window")
            : String(localized: "Focuses this window")
    }

    var help: String {
        if window.windowCount == 1 {
            return window.isAppHidden
                ? String(localized: "Unhide and focus \(window.appName)")
                : String(localized: "Focus \(window.appName) window")
        }
        if window.isAppHidden {
            return String(localized: "Show \(window.appName) windows — app hidden")
        }
        if window.hasHiddenWindows {
            return String(
                localized: "Show \(window.appName) windows — \(window.hiddenWindowCount) of \(window.windowCount) hidden"
            )
        }
        return String(localized: "Show \(window.appName) windows")
    }
}

struct WorkspaceBarWindowListRowPresentation {
    let window: WorkspaceBarWindowInfo

    var accessibilityValue: String {
        var values: [String] = []
        if window.isFocused {
            values.append(String(localized: "Focused"))
        }
        if window.isAppHidden {
            values.append(String(localized: "App hidden"))
        }
        return values.joined(separator: ", ")
    }

    var accessibilityHint: String {
        window.isAppHidden
            ? String(localized: "Unhides the app and focuses this window")
            : String(localized: "Focuses this window")
    }

    var help: String {
        window.isAppHidden
            ? String(localized: "Unhide and focus \(window.title)")
            : String(localized: "Focus \(window.title)")
    }
}

@MainActor
struct WindowIconView: View {
    let window: WorkspaceBarWindowItem
    let iconSize: CGFloat
    let isFocused: Bool
    let isInFocusedWorkspace: Bool
    let context: WorkspaceBarWindowContext
    let animationsEnabled: Bool
    let showAccentHighlights: Bool
    let inactiveIconOpacity: Double?
    let accentColor: Color?
    let textColor: Color?
    let onFocusWindow: (WindowHandle) -> Void

    @State private var isHovered = false
    @State private var showingWindowList = false

    private var resolvedAccentColor: Color {
        accentColor ?? .accentColor
    }

    var body: some View {
        let presentation = WorkspaceBarWindowPresentation(
            window: window,
            context: context,
            isFocused: isFocused,
            isInFocusedWorkspace: isInFocusedWorkspace,
            inactiveIconOpacity: inactiveIconOpacity
        )
        Button {
            if window.windowCount > 1 {
                showingWindowList = true
            } else {
                onFocusWindow(window.handle)
            }
        } label: {
            AppIconImage(icon: window.icon)
                .frame(width: iconSize, height: iconSize)
                .overlay {
                    if presentation.appliesHiddenTint {
                        Color(nsColor: .systemRed)
                            .opacity(0.32)
                            .blendMode(.sourceAtop)
                    }
                }
                .opacity(presentation.iconOpacity)
                .shadow(color: resolvedAccentColor.opacity(glowOpacity), radius: glowRadius)
                .accessibilityHidden(true)
                .overlay(alignment: .topTrailing) {
                    if window.windowCount > 1 {
                        WindowCountBadge(count: window.windowCount, iconSize: iconSize, textColor: textColor)
                            .offset(x: iconSize * 0.2, y: -max(5, iconSize * 0.1))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let hiddenIndicatorStyle = presentation.hiddenIndicatorStyle {
                        WorkspaceBarHiddenIndicator(style: hiddenIndicatorStyle, iconSize: iconSize)
                            .offset(x: iconSize * 0.2, y: max(5, iconSize * 0.1))
                    }
                }
                .frame(minWidth: max(16, iconSize + 4), minHeight: max(16, iconSize + 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(scale)
        .animation(animationsEnabled ? .easeInOut(duration: 0.15) : nil, value: isFocused)
        .animation(animationsEnabled ? .easeInOut(duration: 0.1) : nil, value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .sheet(isPresented: $showingWindowList) {
            WindowListSheet(
                windows: window.allWindows,
                appName: window.appName,
                accentColor: accentColor,
                textColor: textColor,
                onFocusWindow: { handle in
                    onFocusWindow(handle)
                    showingWindowList = false
                }
            )
        }
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(presentation.accessibilityValue)
        .accessibilityHint(presentation.accessibilityHint)
        .help(presentation.help)
    }

    private var scale: CGFloat {
        if isFocused {
            1.1
        } else if isHovered {
            1.05
        } else {
            1.0
        }
    }

    private var glowRadius: CGFloat {
        isFocused && showAccentHighlights ? 4 : 0
    }

    private var glowOpacity: Double {
        isFocused && showAccentHighlights ? 0.5 : 0
    }
}

@MainActor
private struct WorkspaceBarHiddenIndicator: View {
    let style: WorkspaceBarHiddenIndicatorStyle
    let iconSize: CGFloat

    private var badgeSize: CGFloat {
        max(8, iconSize * 0.48)
    }

    var body: some View {
        Group {
            switch style {
            case .appHidden:
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: max(6, iconSize * 0.3), weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: badgeSize, height: badgeSize)
                    .background(Color(nsColor: .systemRed), in: Circle())
            case .partiallyHidden:
                Image(systemName: "eye.slash")
                    .font(.system(size: max(6, iconSize * 0.3), weight: .semibold))
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .frame(width: badgeSize, height: badgeSize)
                    .background(.regularMaterial, in: Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(Color(nsColor: .systemRed).opacity(0.72), lineWidth: 0.75)
                    }
            }
        }
        .accessibilityHidden(true)
    }
}

@MainActor
struct AppIconImage: View {
    let icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable().scaledToFit()
            } else {
                Image(systemName: "app.dashed")
                    .resizable().scaledToFit()
            }
        }
    }
}

@MainActor
struct WindowCountBadge: View {
    let count: Int
    var prefix = ""
    let iconSize: CGFloat
    let textColor: Color?

    var body: some View {
        Text("\(prefix)\(count)")
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundColor(textColor ?? .primary)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(
                Capsule(style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 0.5)
                    }
            )
            .frame(minWidth: max(12, iconSize * 0.55), minHeight: max(12, iconSize * 0.55))
            .accessibilityHidden(true)
    }
}

@MainActor
private struct WindowListSheet: View {
    let windows: [WorkspaceBarWindowInfo]
    let appName: String
    let accentColor: Color?
    let textColor: Color?
    let onFocusWindow: (WindowHandle) -> Void
    @Environment(\.dismiss) private var dismiss

    private var resolvedAccentColor: Color {
        accentColor ?? .accentColor
    }

    private var resolvedPrimaryTextColor: Color {
        textColor ?? .primary
    }

    private var resolvedSecondaryTextColor: Color {
        textColor ?? .secondary
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(appName)
                    .font(.headline)
                    .padding()
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .padding()
            }
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            List(windows) { windowInfo in
                let presentation = WorkspaceBarWindowListRowPresentation(window: windowInfo)
                Button {
                    onFocusWindow(windowInfo.handle)
                } label: {
                    HStack {
                        Text(windowInfo.title)
                            .foregroundColor(windowInfo
                                .isFocused ? resolvedPrimaryTextColor : resolvedSecondaryTextColor)
                        Spacer()
                        if windowInfo.isFocused {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(resolvedAccentColor)
                        }
                        if windowInfo.isAppHidden {
                            AppHiddenStatusBadge()
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(windowInfo.title)
                .accessibilityValue(presentation.accessibilityValue)
                .accessibilityHint(presentation.accessibilityHint)
                .help(presentation.help)
            }
        }
        .frame(minWidth: 300, minHeight: 200)
    }
}
