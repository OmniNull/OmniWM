// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import SwiftUI

@MainActor
struct ScratchpadPillView: View {
    let item: WorkspaceBarScratchpadItem
    let iconSize: CGFloat
    let itemHeight: CGFloat
    let animationsEnabled: Bool
    let showItemBackgrounds: Bool
    let showAccentHighlights: Bool
    let inactiveIconOpacity: Double?
    let accentColor: Color?
    let textColor: Color?
    let onActivateScratchpad: (Int) -> Void

    @State private var isHovered = false
    @Environment(\.workspaceBarInteraction) private var interaction

    private var resolvedAccentColor: Color {
        accentColor ?? .accentColor
    }

    private var resolvedSecondaryTextColor: Color {
        textColor ?? .secondary
    }

    private var isHighlighted: Bool {
        item.isRevealed || item.isFocused
    }

    private var shownWindows: ArraySlice<WorkspaceBarWindowItem> {
        item.windows.prefix(WorkspaceBarScratchpadLayout.maximumVisibleAppIcons)
    }

    private var hiddenAppIconCount: Int {
        max(0, item.windows.count - shownWindows.count)
    }

    var body: some View {
        Button {
            onActivateScratchpad(item.index)
        } label: {
            HStack(spacing: item.presentation == .compact ? 3 : 5) {
                if item.presentation == .expanded {
                    Image(systemName: "tray.fill")
                        .font(.system(size: max(10, iconSize * 0.64), weight: .semibold))
                        .foregroundColor(
                            isHighlighted && showAccentHighlights
                                ? resolvedAccentColor
                                : resolvedSecondaryTextColor
                        )
                        .accessibilityHidden(true)
                }

                Text(item.name)
                    .font(.system(size: max(9, iconSize * 0.6), weight: .medium))
                    .foregroundColor(
                        isHighlighted && showAccentHighlights
                            ? resolvedAccentColor
                            : resolvedSecondaryTextColor
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(
                        maxWidth: item.presentation == .compact
                            ? WorkspaceBarScratchpadLayout.compactLabelMaximumWidth
                            : nil
                    )
                    .accessibilityHidden(true)

                if item.presentation == .compact {
                    WindowCountBadge(
                        count: item.windowCount,
                        iconSize: iconSize,
                        textColor: textColor
                    )
                } else {
                    ForEach(shownWindows) { window in
                        AppIconImage(icon: window.icon)
                            .frame(width: iconSize, height: iconSize)
                            .opacity(
                                WorkspaceBarIconOpacity.scratchpad(
                                    isFocused: window.isFocused,
                                    configured: inactiveIconOpacity
                                )
                            )
                            .accessibilityHidden(true)
                    }

                    if hiddenAppIconCount > 0 {
                        WindowCountBadge(
                            count: hiddenAppIconCount,
                            prefix: "+",
                            iconSize: iconSize,
                            textColor: textColor
                        )
                    }
                }
            }
            .padding(.horizontal, item.presentation == .compact ? 5 : 8)
            .frame(height: itemHeight)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .scaleEffect(scale)
        .animation(animationsEnabled ? .easeInOut(duration: 0.12) : nil, value: isHovered)
        .animation(animationsEnabled ? .easeInOut(duration: 0.15) : nil, value: isHighlighted)
        .background {
            if showItemBackgrounds {
                Capsule(style: .continuous)
                    .fill(
                        isHighlighted && showAccentHighlights
                            ? resolvedAccentColor.opacity(0.18)
                            : Color.secondary.opacity(0.08)
                    )
                    .background(.regularMaterial, in: Capsule(style: .continuous))
            }
            if item.isFocused && showAccentHighlights {
                Capsule(style: .continuous)
                    .strokeBorder(resolvedAccentColor, lineWidth: 1.2)
            } else if showItemBackgrounds {
                Capsule(style: .continuous)
                    .strokeBorder(Color.secondary.opacity(item.isVisible ? 0.36 : 0.22), lineWidth: 0.8)
            }
        }
        .workspaceBarHitRegion(.scratchpad(item.index))
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityLabel("Scratchpad \(item.name)")
        .accessibilityAction(.showMenu) {
            interaction?.onShowMenu(.scratchpad(item.index))
        }
        .accessibilityValue(accessibilityValue)
        .help(item.isVisible
            ? String(localized: "Scratchpad \(item.name): \(windowSummary), visible")
            : String(localized: "Scratchpad \(item.name): \(windowSummary), hidden"))
    }

    private var scale: CGFloat {
        if item.isFocused {
            1.04
        } else if isHovered {
            1.03
        } else {
            1
        }
    }

    private var windowSummary: String {
        item.windowCount == 1
            ? item.windows[0].appName
            : String(localized: "\(item.windowCount) windows")
    }

    private var accessibilityValue: String {
        var parts = [windowSummary, item.isVisible ? String(localized: "Visible") : String(localized: "Hidden")]
        if item.isFocused {
            parts.append(String(localized: "Focused"))
        }
        return parts.joined(separator: ", ")
    }
}
