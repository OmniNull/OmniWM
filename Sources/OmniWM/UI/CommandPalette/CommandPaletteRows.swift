// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Carbon
import Observation
import SwiftUI

struct CommandPaletteWindowRow: View {
    let item: CommandPaletteWindowItem
    let isSelected: Bool
    let isSummonRightAvailable: Bool
    let onSelect: () -> Void

    private var summonHint: CommandPalettePresentation.InlineHint? {
        guard isSelected else { return nil }
        return CommandPalettePresentation.selectedWindowHint(isSummonRightAvailable: isSummonRightAvailable)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                if let icon = item.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 28, height: 28)
                } else {
                    Image(systemName: "app.fill")
                        .font(.system(size: 22))
                        .frame(width: 28, height: 28)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayTitle)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(item.appName)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 8) {
                        if let summonHint {
                            Text(summonHint.title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                            CommandPaletteShortcutBadge(text: summonHint.shortcut)
                        }

                        if item.isAppHidden {
                            AppHiddenStatusBadge()
                        }

                        Text(item.workspaceName)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.18))
                            .clipShape(Capsule())
                    }

                    ForEach(markLabels, id: \.self) { markLabel in
                        Text(markLabel)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
            }
            .modifier(CommandPaletteResultRowStyle(isSelected: isSelected))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(item.isAppHidden
            ? String(localized: "Unhides the app and focuses this window")
            : String(localized: "Focuses this window"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var displayTitle: String {
        item.title.isEmpty ? item.appName : item.title
    }

    var markLabels: [String] {
        item.markNames.map { "Mark: \($0)" }
    }

    var accessibilityLabel: String {
        let windowAndApp = displayTitle == item.appName ? item.appName : "\(displayTitle), \(item.appName)"
        guard !markLabels.isEmpty else { return windowAndApp }
        return ([windowAndApp] + markLabels).joined(separator: ", ")
    }

    private var accessibilityValue: String {
        if item.isAppHidden {
            return String(localized: "App hidden, Workspace \(item.workspaceName)")
        }
        return String(localized: "Workspace \(item.workspaceName)")
    }
}

struct CommandPaletteMenuRow: View {
    let item: MenuItemModel
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if !item.parentTitles.isEmpty {
                    Text(item.parentTitles.joined(separator: " > "))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let shortcut = item.keyboardShortcut {
                CommandPaletteShortcutBadge(text: shortcut)
            }
        }
        .modifier(CommandPaletteResultRowStyle(isSelected: isSelected))
    }
}

struct CommandPaletteCommandRow: View {
    let item: CommandPaletteCommandItem
    let isSelected: Bool
    let showsCategory: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: "command")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.spec.localizedTitle)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if showsCategory {
                        Text(item.spec.category.localizedDisplayName)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                .layoutPriority(1)

                Spacer(minLength: 8)

                Text(item.spec.layoutCompatibility.localizedDisplayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(item.isLayoutCompatible ? .secondary : .orange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        item.isLayoutCompatible ? Color.secondary.opacity(0.14) : Color.orange.opacity(0.16)
                    )
                    .clipShape(Capsule())

                CommandPaletteShortcutBadge(
                    text: item.shortcut,
                    enabled: item.hasShortcut
                )
            }
            .modifier(CommandPaletteResultRowStyle(isSelected: isSelected && item.isLayoutCompatible))
        }
        .buttonStyle(.plain)
        .disabled(!item.isLayoutCompatible)
        .opacity(item.isLayoutCompatible ? 1 : 0.55)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.spec.localizedTitle)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(item.isLayoutCompatible
            ? String(localized: "Runs this OmniWM command")
            : String(localized: "Unavailable in the current layout"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected && item.isLayoutCompatible ? .isSelected : [])
    }

    private var accessibilityValue: String {
        String(
            localized: "\(item.spec.category.localizedDisplayName), \(item.spec.layoutCompatibility.localizedDisplayName), \(item.shortcut)"
        )
    }
}

struct CommandPaletteClipboardRow: View {
    let item: ClipboardPaletteItem
    let isSelected: Bool
    let onCopy: () -> Void
    let onPaste: () -> Void
    let onPasteWithoutFormatting: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void
    let onHighlight: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onCopy) {
                HStack(spacing: 10) {
                    Image(systemName: symbolName)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(item.title)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if item.isPinned {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                        Text(item.subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .layoutPriority(1)

                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy")
            .accessibilityLabel(String(localized: "Copy \(item.title)"))

            Button(action: onPaste) {
                Image(systemName: "arrow.turn.down.left")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help("Paste")
            .accessibilityLabel(String(localized: "Paste \(item.title)"))
            .foregroundColor(.secondary)

            Menu {
                if item.canPastePlainText {
                    Button("Paste Without Formatting") {
                        onPasteWithoutFormatting()
                    }
                }
                Button(item.isPinned ? String(localized: "Unpin") : String(localized: "Pin"), action: onPin)
                Button("Delete", systemImage: "trash", action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 18, height: 18)
            }
            .menuStyle(.borderlessButton)
            .help("More Actions")
            .accessibilityLabel(String(localized: "More actions for \(item.title)"))
            .foregroundColor(.secondary)
        }
        .modifier(CommandPaletteResultRowStyle(isSelected: isSelected))
        .onHover { hovering in
            if hovering { onHighlight() }
        }
    }

    private var symbolName: String {
        switch item.kind {
        case .text:
            "text.alignleft"
        case .richText:
            "doc.richtext"
        case .html:
            "chevron.left.forwardslash.chevron.right"
        case .image:
            "photo"
        case .fileURL:
            "doc"
        case .other:
            "doc.questionmark"
        }
    }
}

private struct CommandPaletteResultRowStyle: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.1 : 0))
            }
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
    }
}
