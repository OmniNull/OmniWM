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

    @ViewBuilder
    private var sections: some View {
        let results = controller.unifiedResults
        if !results.topHits.isEmpty {
            heading(
                String(localized: "Top Hits"),
                hint: CommandPalettePresentation.topHitShortcutRange(count: results.topHits.count)
            )
            ForEach(results.topHits, id: \.self) { row($0) }
        }
        ForEach(results.groups, id: \.mode) { group in
            heading(group.mode.localizedDisplayName)
            ForEach(group.rows, id: \.self) { row($0) }
            if group.hasMore {
                showAllRow(group.mode)
            }
        }
    }

    private func heading(_ title: String, hint: String? = nil) -> some View {
        HStack {
            Text(title)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if let hint {
                Text(hint)
                    .accessibilityLabel(String(localized: "Open with \(hint)"))
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(.secondary)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 4)
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
                CommandPaletteMenuRow(item: item, isSelected: controller.selectedItemID == id)
                    .id(id)
                    .onTapGesture { activate(id) }
            }
        case let .clipboard(itemID):
            if let item = controller.clipboardItems.first(where: { $0.id == itemID }) {
                clipboardRow(item)
            }
        case let .command(commandID):
            if let item = controller.commandItems.first(where: { $0.id == commandID }) {
                CommandPaletteCommandRow(
                    item: item,
                    isSelected: controller.selectedItemID == id,
                    showsCategory: true,
                    onSelect: { activate(id) }
                )
                .id(id)
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
        case .executable,
             .showAll:
            EmptyView()
        }
    }

    private func windowRow(_ item: CommandPaletteWindowItem) -> some View {
        CommandPaletteWindowRow(
            item: item,
            isSelected: controller.selectedItemID == .window(item.id),
            isSummonRightAvailable: controller.isSummonRightAvailable && controller.allowsWindowAlternateAction(item),
            onSelect: { activate(.window(item.id)) }
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
            onHighlight: { controller.selectedItemID = id }
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
            }
            .modifier(CommandPaletteResultRowStyle(isSelected: isSelected))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
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
        controller.selectedItemID = id
        controller.selectCurrent(trigger: trigger)
    }
}
