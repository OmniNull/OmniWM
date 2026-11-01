// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

/// Presents the focused application's menu bar inside the status menu, below the
/// controls grid and above OmniWM's own rows.
struct StatusMenuAppMenuSection: View {
    let model: StatusMenuModel

    @State private var expandedGroupID: String?
    @State private var loadingGroupID: String?

    var body: some View {
        if let menu = model.appMenu, !menu.isEmpty {
            MenuSectionLabel(text: String(localized: "APP MENU"))
            VStack(spacing: 0) {
                ForEach(menu.groups) { group in
                    StatusMenuAppMenuGroupRow(
                        group: group,
                        isExpanded: expandedGroupID == group.id,
                        isLoading: loadingGroupID == group.id
                    ) {
                        toggle(group)
                    }
                    if expandedGroupID == group.id {
                        StatusMenuAppMenuItemList(items: model.appMenuItemsByGroup[group.id] ?? [])
                    }
                }
            }
            .padding(.bottom, 6)
            MenuDivider()
        }
    }

    private func toggle(_ group: StatusMenuAppMenuGroup) {
        if expandedGroupID == group.id {
            expandedGroupID = nil
            return
        }
        expandedGroupID = group.id
        guard model.appMenuItemsByGroup[group.id] == nil else { return }
        loadingGroupID = group.id
        Task { @MainActor in
            await Task.yield()
            model.prepareAppMenuItems(for: group)
            if loadingGroupID == group.id {
                loadingGroupID = nil
            }
        }
    }
}

private struct StatusMenuAppMenuGroupRow: View {
    let group: StatusMenuAppMenuGroup
    let isExpanded: Bool
    let isLoading: Bool
    let action: @MainActor () -> Void

    @Environment(MotionPolicy.self) private var motionPolicy
    @Environment(\.statusMenuFocus) private var focus
    @State private var isHovered = false

    private var isFocused: Bool {
        focus?.wrappedValue == .appMenuGroup(group.id)
    }

    private var isHighlighted: Bool {
        isHovered || isExpanded
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(group.title)
                    .font(.system(size: 13))
                    .foregroundStyle(isHighlighted ? .white : Color(nsColor: .labelColor))
                Spacer(minLength: 0)
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(
                            isHighlighted ? .white : Color(nsColor: .tertiaryLabelColor)
                        )
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .focusEffectDisabled()
        .modifier(StatusMenuFocusModifier(item: .appMenuGroup(group.id)))
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHighlighted ? Color(nsColor: .controlAccentColor).opacity(0.32) : .clear)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
        }
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
            }
        }
        .onKeyPress(keys: [.return, .space]) { press in
            guard StatusMenuKeyboardPolicy.acceptsModifiers(press.modifiers) else { return .ignored }
            action()
            return .handled
        }
        .onHover { isHovered = $0 }
        .animation(motionPolicy.animationsEnabled ? .easeOut(duration: 0.12) : nil, value: isHighlighted)
        .accessibilityValue(
            isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed")
        )
    }
}

private struct StatusMenuAppMenuItemList: View {
    let items: [StatusMenuAppMenuItem]

    var body: some View {
        if items.isEmpty {
            Text(String(localized: "No commands available"))
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .padding(.leading, 24)
                .frame(height: 24, alignment: .leading)
        } else {
            ForEach(items) { item in
                if item.isSeparator {
                    MenuDivider()
                } else {
                    StatusMenuAppMenuItemRow(item: item)
                }
            }
        }
    }
}

private struct StatusMenuAppMenuItemRow: View {
    let item: StatusMenuAppMenuItem

    @Environment(MotionPolicy.self) private var motionPolicy
    @Environment(\.statusMenuDismiss) private var dismissMenu
    @Environment(\.statusMenuFocus) private var focus
    @State private var isHovered = false

    private var isFocused: Bool {
        focus?.wrappedValue == .appMenuItem(item.id)
    }

    private var isActionable: Bool {
        item.isEnabled && !item.hasSubmenu
    }

    private var isHighlighted: Bool {
        isActionable && isHovered
    }

    var body: some View {
        Button {
            guard isActionable else { return }
            dismissMenu {
                StatusMenuAppMenuLoader.press(item)
            }
        } label: {
            HStack(spacing: 8) {
                Text(item.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(labelColor)
                Spacer(minLength: 8)
                if item.hasSubmenu {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                } else if let shortcut = item.shortcut {
                    Text(shortcut)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(
                            isHighlighted ? .white : Color(nsColor: .tertiaryLabelColor)
                        )
                }
            }
            .padding(.leading, 24)
            .padding(.trailing, 12)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isActionable)
        .focusable()
        .focusEffectDisabled()
        .modifier(StatusMenuFocusModifier(item: .appMenuItem(item.id)))
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHighlighted ? Color(nsColor: .controlAccentColor).opacity(0.32) : .clear)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
        }
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
            }
        }
        .onKeyPress(keys: [.return, .space]) { press in
            guard isActionable, StatusMenuKeyboardPolicy.acceptsModifiers(press.modifiers) else {
                return .ignored
            }
            dismissMenu {
                StatusMenuAppMenuLoader.press(item)
            }
            return .handled
        }
        .onHover { isHovered = $0 }
        .animation(motionPolicy.animationsEnabled ? .easeOut(duration: 0.12) : nil, value: isHighlighted)
    }

    private var labelColor: Color {
        guard isActionable else { return Color(nsColor: .disabledControlTextColor) }
        return isHighlighted ? .white : Color(nsColor: .labelColor)
    }
}
