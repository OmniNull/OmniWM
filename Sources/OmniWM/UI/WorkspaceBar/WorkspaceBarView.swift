// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

@MainActor
struct WorkspaceBarView: View {
    let model: WorkspaceBarModel
    var slice: WorkspaceBarIslandSlice = .all
    var showsSystemStatsButton = false
    @Bindable var motionPolicy: MotionPolicy
    let onFocusWorkspace: (WorkspaceBarItem) -> Void
    let onFocusWindow: (WindowHandle) -> Void
    let onActivateScratchpad: (Int) -> Void
    var onToggleSystemStats: () -> Void = {}
    var onSystemStatsAnchorChange: (NSView?) -> Void = { _ in }
    var interaction: WorkspaceBarIslandInteraction?
    var dragPresentation: WorkspaceBarDragPresentation?

    var body: some View {
        if model.snapshot.orientation.isVertical {
            ScrollView(.vertical) {
                content.fixedSize(horizontal: false, vertical: true)
            }
            .scrollIndicators(.hidden)
            .frame(width: model.snapshot.barHeight)
        } else {
            content
        }
    }

    private var content: some View {
        WorkspaceBarContentView(
            snapshot: model.snapshot,
            slice: slice,
            showsSystemStatsButton: showsSystemStatsButton,
            animationsEnabled: motionPolicy.animationsEnabled,
            onFocusWorkspace: onFocusWorkspace,
            onFocusWindow: onFocusWindow,
            onActivateScratchpad: onActivateScratchpad,
            onToggleSystemStats: onToggleSystemStats,
            onSystemStatsAnchorChange: onSystemStatsAnchorChange
        )
        .environment(\.workspaceBarInteraction, interaction)
        .environment(model)
        .environment(dragPresentation)
    }
}

@MainActor
struct WorkspaceBarMeasurementView: View {
    let snapshot: WorkspaceBarSnapshot
    var slice: WorkspaceBarIslandSlice = .all
    var showsSystemStatsButton = false

    var body: some View {
        WorkspaceBarContentView(
            snapshot: snapshot,
            slice: slice,
            showsSystemStatsButton: showsSystemStatsButton,
            animationsEnabled: false,
            onFocusWorkspace: { _ in },
            onFocusWindow: { _ in },
            onActivateScratchpad: { _ in },
            onToggleSystemStats: {},
            onSystemStatsAnchorChange: { _ in }
        )
        .fixedSize(horizontal: !snapshot.orientation.isVertical, vertical: snapshot.orientation.isVertical)
    }
}

@MainActor
private struct WorkspaceBarContentView: View {
    let snapshot: WorkspaceBarSnapshot
    var slice: WorkspaceBarIslandSlice = .all
    var showsSystemStatsButton = false
    let animationsEnabled: Bool
    let onFocusWorkspace: (WorkspaceBarItem) -> Void
    let onFocusWindow: (WindowHandle) -> Void
    let onActivateScratchpad: (Int) -> Void
    let onToggleSystemStats: () -> Void
    let onSystemStatsAnchorChange: (NSView?) -> Void

    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var itemHeight: CGFloat {
        max(16, snapshot.barHeight - 4)
    }

    private var iconSize: CGFloat {
        max(12, itemHeight - 6)
    }

    private let workspaceSpacing: CGFloat = 8
    private let windowSpacing: CGFloat = 2
    private let cornerRadius: CGFloat = 6

    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(snapshot.backgroundOpacity)
            : Color.black.opacity(snapshot.backgroundOpacity * 0.5)
    }

    private var accentColor: Color? {
        snapshot.accentColor?.swiftUIColor
    }

    private var textColor: Color? {
        snapshot.textColor?.swiftUIColor
    }

    private var barShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
    }

    var body: some View {
        snapshot.orientation.stack(spacing: workspaceSpacing) {
            ForEach(slice.items(in: snapshot), id: \.id) { item in
                WorkspaceItemView(
                    item: item,
                    iconSize: iconSize,
                    itemHeight: itemHeight,
                    windowSpacing: windowSpacing,
                    cornerRadius: cornerRadius,
                    animationsEnabled: animationsEnabled,
                    showLabels: snapshot.showLabels,
                    showItemBackgrounds: snapshot.showItemBackgrounds,
                    showAccentHighlights: snapshot.showAccentHighlights,
                    inactiveIconOpacity: snapshot.inactiveIconOpacity,
                    accentColor: accentColor,
                    textColor: textColor,
                    onFocusWorkspace: { onFocusWorkspace(item) },
                    onFocusWindow: onFocusWindow
                )
            }

            ForEach(slice.scratchpads(in: snapshot)) { scratchpad in
                ScratchpadPillView(
                    item: scratchpad,
                    iconSize: iconSize,
                    itemHeight: itemHeight,
                    animationsEnabled: animationsEnabled,
                    showItemBackgrounds: snapshot.showItemBackgrounds,
                    showAccentHighlights: snapshot.showAccentHighlights,
                    inactiveIconOpacity: snapshot.inactiveIconOpacity,
                    accentColor: accentColor,
                    textColor: textColor,
                    onActivateScratchpad: onActivateScratchpad
                )
            }

            if showsSystemStatsButton {
                SystemStatsButtonView(
                    itemHeight: itemHeight,
                    showItemBackgrounds: snapshot.showItemBackgrounds,
                    showAccentHighlights: snapshot.showAccentHighlights,
                    accentColor: accentColor,
                    textColor: textColor,
                    onToggle: onToggleSystemStats,
                    onAnchorChange: onSystemStatsAnchorChange
                )
            }
        }
        .environment(\.workspaceBarOrientation, snapshot.orientation)
        .padding(snapshot.orientation.isVertical ? .vertical : .horizontal, 4)
        .frame(maxWidth: snapshot.backgroundStyle == .solidBlack ? .infinity : nil, alignment: .leading)
        .frame(
            width: snapshot.orientation.isVertical ? itemHeight + 4 : nil,
            height: snapshot.orientation.isVertical ? nil : itemHeight + 4
        )
        .background {
            if snapshot.backgroundStyle == .solidBlack {
                Rectangle().fill(Color.black)
            } else if snapshot.backgroundStyle == .material {
                if accessibilityReduceTransparency {
                    barShape.fill(Color(NSColor.windowBackgroundColor).opacity(0.96))
                } else {
                    barShape
                        .fill(backgroundColor)
                        .background(.ultraThinMaterial, in: barShape)
                }

                barShape.strokeBorder(
                    colorSchemeContrast == .increased
                        ? Color.primary.opacity(0.45)
                        : Color.secondary.opacity(0.18),
                    lineWidth: colorSchemeContrast == .increased ? 1 : 0.5
                )
            }
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}

@MainActor
private struct WorkspaceItemView: View {
    let item: WorkspaceBarItem
    let iconSize: CGFloat
    let itemHeight: CGFloat
    let windowSpacing: CGFloat
    let cornerRadius: CGFloat
    let animationsEnabled: Bool
    let showLabels: Bool
    let showItemBackgrounds: Bool
    let showAccentHighlights: Bool
    let inactiveIconOpacity: Double?
    let accentColor: Color?
    let textColor: Color?
    let onFocusWorkspace: () -> Void
    let onFocusWindow: (WindowHandle) -> Void

    @State private var isHovered = false
    @Environment(\.workspaceBarOrientation) private var orientation
    @Environment(\.workspaceBarInteraction) private var interaction
    @Environment(WorkspaceBarDragPresentation.self) private var drag: WorkspaceBarDragPresentation?

    private var isDropTarget: Bool {
        drag?.highlights.contains(.workspace(item.id)) == true
    }

    private var dropGapIndex: Int? {
        drag?.highlights.lazy.compactMap { highlight -> Int? in
            guard case let .gap(workspaceId, index) = highlight, workspaceId == item.id else { return nil }
            return index
        }.first
    }

    private func reflowOffset(forIconAt index: Int) -> CGFloat {
        guard let gap = dropGapIndex else { return 0 }
        let halfGap = min(8, iconSize * 0.4) / 2
        return index < gap ? -halfGap : halfGap
    }

    var body: some View {
        orientation.stack(spacing: windowSpacing) {
            if showLabels {
                WorkspaceLabelButton(
                    item: item,
                    showAccentHighlights: showAccentHighlights,
                    accentColor: accentColor,
                    textColor: textColor,
                    onFocusWorkspace: onFocusWorkspace
                )

                if !item.windows.isEmpty {
                    separator
                }
            } else if item.windows.isEmpty {
                WorkspaceLabelButton(
                    item: item,
                    showAccentHighlights: showAccentHighlights,
                    accentColor: accentColor,
                    textColor: textColor,
                    onFocusWorkspace: onFocusWorkspace
                )
            }

            ForEach(Array(item.tiledWindows.enumerated()), id: \.element.id) { index, window in
                WindowIconView(
                    window: window,
                    workspaceId: item.id,
                    iconSize: iconSize,
                    isFocused: window.isFocused,
                    isInFocusedWorkspace: item.isFocused,
                    context: .tiled,
                    animationsEnabled: animationsEnabled,
                    showAccentHighlights: showAccentHighlights,
                    inactiveIconOpacity: inactiveIconOpacity,
                    accentColor: accentColor,
                    textColor: textColor,
                    onFocusWindow: onFocusWindow
                )
                .offset(
                    x: orientation.isVertical ? 0 : reflowOffset(forIconAt: index),
                    y: orientation.isVertical ? reflowOffset(forIconAt: index) : 0
                )
                .animation(animationsEnabled ? .spring(duration: 0.2) : nil, value: dropGapIndex)
                .workspaceBarHitRegion(.window(item.id, window.id))
            }

            if !item.tiledWindows.isEmpty && !item.floatingWindows.isEmpty {
                separator
            }

            if !item.floatingWindows.isEmpty {
                FloatingWindowsGroupView(
                    windows: item.floatingWindows,
                    workspaceId: item.id,
                    iconSize: iconSize,
                    itemHeight: itemHeight,
                    isInFocusedWorkspace: item.isFocused,
                    animationsEnabled: animationsEnabled,
                    showItemBackgrounds: showItemBackgrounds,
                    showAccentHighlights: showAccentHighlights,
                    inactiveIconOpacity: inactiveIconOpacity,
                    accentColor: accentColor,
                    textColor: textColor,
                    onFocusWindow: onFocusWindow
                )
            }
        }
        .padding(orientation.isVertical ? .vertical : .horizontal, 8)
        .padding(orientation.isVertical ? .horizontal : .vertical, 2)
        .frame(width: orientation.isVertical ? itemHeight : nil, height: orientation.isVertical ? nil : itemHeight)
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
        .workspaceBarHitRegion(.workspace(item.id))
        .onTapGesture(perform: onFocusWorkspace)
        .background {
            ZStack {
                if showItemBackgrounds, item.isFocused || isHovered {
                    RoundedRectangle(cornerRadius: cornerRadius).fill(.regularMaterial)
                }
                if (showAccentHighlights && item.isFocused) || isDropTarget {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(accentColor ?? .accentColor, lineWidth: isDropTarget ? 1.5 : 1)
                }
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(.showMenu) {
            interaction?.onShowMenu(.workspace(item.id))
        }
    }

    private var separator: some View {
        Rectangle().fill(.separator)
            .frame(width: orientation.isVertical ? iconSize : 1, height: orientation.isVertical ? 1 : iconSize)
            .padding(orientation.isVertical ? .vertical : .horizontal, 2)
            .accessibilityHidden(true)
    }
}

@MainActor
private struct WorkspaceLabelButton: View {
    let item: WorkspaceBarItem
    let showAccentHighlights: Bool
    let accentColor: Color?
    let textColor: Color?
    let onFocusWorkspace: () -> Void

    @Environment(\.workspaceBarOrientation) private var orientation

    private var resolvedAccentColor: Color {
        accentColor ?? .accentColor
    }

    private var resolvedLabelColor: Color {
        if let textColor {
            return textColor
        }
        return item.isFocused && showAccentHighlights ? resolvedAccentColor : .secondary
    }

    var body: some View {
        Button(action: onFocusWorkspace) {
            Text(item.name)
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .foregroundColor(resolvedLabelColor)
                .lineLimit(1)
                .frame(minWidth: 16)
                .fixedSize(horizontal: !orientation.isVertical, vertical: false)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .workspaceBarLabelRegion(item.id)
        .accessibilityLabel("Workspace \(item.name)")
        .accessibilityValue(item.isFocused ? String(localized: "Focused") : "")
        .help("Focus workspace \(item.name)")
    }
}

@MainActor
private struct FloatingWindowsGroupView: View {
    let windows: [WorkspaceBarWindowItem]
    let workspaceId: WorkspaceDescriptor.ID
    let iconSize: CGFloat
    let itemHeight: CGFloat
    let isInFocusedWorkspace: Bool
    let animationsEnabled: Bool
    let showItemBackgrounds: Bool
    let showAccentHighlights: Bool
    let inactiveIconOpacity: Double?
    let accentColor: Color?
    let textColor: Color?
    let onFocusWindow: (WindowHandle) -> Void

    @Environment(\.workspaceBarOrientation) private var orientation

    private var resolvedSecondaryTextColor: Color {
        textColor ?? .secondary
    }

    var body: some View {
        orientation.stack(spacing: 3) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: max(10, iconSize * 0.58), weight: .medium))
                .foregroundStyle(resolvedSecondaryTextColor)
                .accessibilityHidden(true)

            ForEach(windows, id: \.id) { window in
                WindowIconView(
                    window: window,
                    workspaceId: workspaceId,
                    iconSize: iconSize,
                    isFocused: window.isFocused,
                    isInFocusedWorkspace: isInFocusedWorkspace,
                    context: .floating,
                    animationsEnabled: animationsEnabled,
                    showAccentHighlights: showAccentHighlights,
                    inactiveIconOpacity: inactiveIconOpacity,
                    accentColor: accentColor,
                    textColor: textColor,
                    onFocusWindow: onFocusWindow
                )
                .workspaceBarHitRegion(.window(workspaceId, window.id))
            }
        }
        .padding(orientation.isVertical ? .vertical : .horizontal, 5)
        .frame(
            width: orientation.isVertical ? max(16, itemHeight - 2) : nil,
            height: orientation.isVertical ? nil : max(16, itemHeight - 2)
        )
        .background {
            if showItemBackgrounds {
                Capsule(style: .continuous)
                    .fill(.thinMaterial)
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.24), lineWidth: 0.75)
                    }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Floating windows")
    }
}
