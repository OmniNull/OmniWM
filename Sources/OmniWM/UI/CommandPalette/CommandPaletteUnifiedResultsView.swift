// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Observation
import SwiftUI

struct CommandPaletteUnifiedResultsView: View {
    private static let iconPoints: CGFloat = 28

    @Bindable var controller: CommandPaletteController
    @Bindable var motionPolicy: MotionPolicy
    @State private var icons = LauncherIconStore.shared

    var body: some View {
        if controller.showsUnifiedWindowList {
            if controller.windows.isEmpty {
                CommandPaletteEmptyStateView(
                    symbolName: "macwindow.on.rectangle",
                    text: String(localized: "No windows available")
                )
            } else {
                scrollingRows { ForEach(controller.windows) { windowRow($0) } }
            }
        } else if controller.unifiedQuery.isEmpty {
            Color.clear
        } else if controller.unifiedResults.isEmpty {
            if controller.isUnifiedSearchLoading {
                CommandPaletteLoadingView(text: String(localized: "Searching…"))
            } else {
                CommandPaletteEmptyStateView(symbolName: "magnifyingglass", text: String(localized: "No results"))
            }
        } else {
            scrollingRows { sections }
        }
    }

    private func scrollingRows(@ViewBuilder _ rows: () -> some View) -> some View {
        let content = rows()
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    content
                }
                .padding(.vertical, 8)
            }
            .onChange(of: controller.selectionScrollRequest) { _, _ in
                guard let selectedItemID = controller.selectedItemID else { return }
                if motionPolicy.animationsEnabled {
                    withAnimation(.easeInOut(duration: 0.1)) { proxy.scrollTo(selectedItemID) }
                } else {
                    proxy.scrollTo(selectedItemID)
                }
            }
        }
    }

    private var sections: some View {
        ForEach(controller.unifiedResults.lines, id: \.self) { line in
            switch line {
            case .topHitsHeading:
                heading(String(localized: "Top Hits"))
            case let .groupHeading(mode):
                heading(mode.localizedDisplayName)
            case let .row(id):
                row(id)
            }
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func topHitShortcut(_ id: CommandPaletteSelectionID) -> String? {
        controller.unifiedResults.topHits.firstIndex(of: id).map(CommandPalettePresentation.topHitShortcut(at:))
    }

    private func menuRow(_ id: CommandPaletteSelectionID, _ item: MenuItemModel) -> some View {
        CommandPaletteMenuRow(item: item, isSelected: controller.selectedItemID == id, shortcutHint: topHitShortcut(id))
            .id(id)
            .onTapGesture { activate(id) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(([item.title] + item.parentTitles).joined(separator: ", "))
            .accessibilityValue(CommandPalettePresentation.accessibilityValue(
                item.keyboardShortcut ?? "",
                topHitShortcut: topHitShortcut(id)
            ))
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(controller.selectedItemID == id ? .isSelected : [])
    }

    private func commandRow(_ id: CommandPaletteSelectionID, _ item: CommandPaletteCommandItem) -> some View {
        CommandPaletteCommandRow(
            item: item,
            isSelected: controller.selectedItemID == id,
            showsCategory: true,
            onSelect: { activate(id) },
            shortcutHint: topHitShortcut(id)
        )
        .id(id)
    }

    @ViewBuilder
    private func row(_ id: CommandPaletteSelectionID) -> some View {
        switch id {
        case let .window(token):
            if let item = controller.windows.first(where: { $0.id == token }) {
                windowRow(item)
            }
        case let .menu(itemID):
            if let item = controller.menuItems.first(where: { $0.id == itemID }) {
                menuRow(id, item)
            }
        case let .clipboard(itemID):
            if let item = controller.clipboardItems.first(where: { $0.id == itemID }) {
                clipboardRow(item)
            }
        case let .command(commandID):
            if let item = controller.commandItems.first(where: { $0.id == commandID }) {
                commandRow(id, item)
            }
        case let .launcherEntry(entryID):
            if let entry = controller.launcherSavedEntries.first(where: { $0.id == entryID }) {
                launcherRow(
                    id,
                    name: entry.name,
                    subtitle: entry.kind == .command ? entry.command : entry.path,
                    symbolName: entry.symbol,
                    image: nil
                )
            }
        case let .application(sectionID, itemID):
            if let item = controller.applicationResult(sectionID, itemID) {
                applicationRow(id, item)
            }
        case let .file(sectionID, itemID):
            if let item = controller.fileResult(sectionID, itemID) {
                fileRow(id, item)
            }
        case .executable:
            EmptyView()
        case let .showAll(mode):
            showAllRow(mode)
        }
    }

    private func windowRow(_ item: CommandPaletteWindowItem) -> some View {
        CommandPaletteWindowRow(
            item: item,
            isSelected: controller.selectedItemID == .window(item.id),
            isSummonRightAvailable: controller.isSummonRightAvailable && controller.allowsWindowAlternateAction(item),
            onSelect: { activate(.window(item.id)) },
            shortcutHint: topHitShortcut(.window(item.id))
        )
        .id(CommandPaletteSelectionID.window(item.id))
    }

    private func clipboardRow(_ item: ClipboardPaletteItem) -> some View {
        let id = CommandPaletteSelectionID.clipboard(item.id)
        return CommandPaletteClipboardRow(
            item: item,
            isSelected: controller.selectedItemID == id,
            onCopy: { activate(id) },
            onPaste: { activate(id, trigger: .alternate) },
            onPasteWithoutFormatting: { controller.pasteClipboardItem(item.id, withoutFormatting: true) },
            onPin: { controller.setClipboardItemPinned(!item.isPinned, id: item.id) },
            onDelete: { controller.deleteClipboardItem(item.id) },
            onHighlight: { controller.highlightUnifiedRow(id) },
            shortcutHint: topHitShortcut(id)
        )
        .id(id)
    }

    private func applicationRow(_ id: CommandPaletteSelectionID, _ item: LauncherApplicationResult) -> some View {
        let scale = NSApp.keyWindow?.backingScaleFactor ?? 2
        return launcherRow(
            id,
            name: item.displayName,
            subtitle: item.categoryName,
            symbolName: "app.fill",
            image: icons.applicationIcon(for: item, points: Self.iconPoints, scale: scale)
        )
        .task(id: item.id) {
            icons.loadApplicationIcon(for: item, points: Self.iconPoints, scale: scale)
        }
    }

    private func fileRow(_ id: CommandPaletteSelectionID, _ item: LauncherFileResult) -> some View {
        let scale = NSApp.keyWindow?.backingScaleFactor ?? 2
        return launcherRow(
            id,
            name: item.displayName,
            subtitle: item.fileURL.deletingLastPathComponent().path,
            symbolName: item.isDirectory ? "folder.fill" : "doc.fill",
            image: icons.fileThumbnail(for: item, points: Self.iconPoints, scale: scale)
        )
        .task(id: item.id) {
            icons.loadFileThumbnail(for: item, points: Self.iconPoints, scale: scale)
        }
        .onDisappear {
            icons.cancelFileThumbnail(for: item, points: Self.iconPoints, scale: scale)
        }
    }

    private func launcherRow(
        _ id: CommandPaletteSelectionID,
        name: String,
        subtitle: String?,
        symbolName: String,
        image: NSImage?
    ) -> some View {
        let isSelected = controller.selectedItemID == id
        return Button {
            activate(id)
        } label: {
            HStack(spacing: 10) {
                Group {
                    if let image {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else {
                        Image(systemName: symbolName)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: Self.iconPoints, height: Self.iconPoints)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                if let shortcut = topHitShortcut(id) {
                    CommandPaletteShortcutBadge(text: shortcut)
                }
            }
            .modifier(CommandPaletteResultRowStyle(isSelected: isSelected))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(CommandPalettePresentation.accessibilityValue(
            subtitle ?? "",
            topHitShortcut: topHitShortcut(id)
        ))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .id(id)
    }

    private func showAllRow(_ mode: CommandPaletteMode) -> some View {
        let id = CommandPaletteSelectionID.showAll(mode)
        let isSelected = controller.selectedItemID == id
        return Button {
            activate(id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: Self.iconPoints)
                Text(String(localized: "Show all in \(mode.localizedDisplayName)"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
            .modifier(CommandPaletteResultRowStyle(isSelected: isSelected))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .id(id)
    }

    private func activate(
        _ id: CommandPaletteSelectionID,
        trigger: CommandPaletteSelectionTrigger = .primary
    ) {
        controller.activateUnifiedRow(id, trigger: trigger)
    }
}
