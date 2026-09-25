// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

struct CommandPaletteLauncherResultsView: View {
    @Environment(\.colorScheme) private var colorScheme

    private struct IconTaskID: Hashable {
        let itemID: String
        let recordSequence: UInt64
        let points: CGFloat
        let scale: CGFloat
        let cacheGeneration: UInt64
        let requestGeneration: Int
    }

    enum ContextAction: Equatable {
        case open
        case reveal
        case quickLook
        case copy
        case copyPath
        case dontSuggest
    }

    @State private var icons = LauncherIconStore.shared
    private static let topID = "launcher-top"

    let mode: CommandPaletteMode
    let applicationSections: [LauncherSection<LauncherApplicationResult>]
    let fileSections: [LauncherSection<LauncherFileResult>]
    let chips: [LauncherChip]
    let selectedChipID: String?
    let viewStyle: LauncherViewStyle
    let selectedItem: LauncherSelection?
    let scrollRequest: Int
    let requestGeneration: Int
    let showsPaths: Bool
    let onChipSelect: (LauncherChip) -> Void
    let onViewStyleChange: (LauncherViewStyle) -> Void
    let onSelect: (LauncherSelection) -> Void
    let onActivate: (LauncherSelection) -> Void
    let onContextAction: (LauncherSelection, ContextAction) -> Void
    let onColumnCountChange: (Int) -> Void

    var body: some View {
        GeometryReader { geometry in
            let columnCount = Self.columnCount(for: mode, width: geometry.size.width, style: viewStyle)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        toolbar
                            .id(Self.topID)
                        if mode == .applications {
                            ForEach(applicationSections) { section in
                                applicationSection(section, columnCount: columnCount)
                            }
                        } else if mode == .files {
                            ForEach(fileSections) { section in
                                fileSection(section, columnCount: columnCount)
                            }
                        }
                        if mode == .applications, applicationSections.allSatisfy({ $0.items.isEmpty }) {
                            emptyState(String(localized: "No applications found"))
                        } else if mode == .files, fileSections.allSatisfy({ $0.items.isEmpty }) {
                            emptyState(String(localized: "No files found"))
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: columnCount, initial: true) { _, count in
                    onColumnCountChange(count)
                }
                .onChange(of: scrollRequest) { _, _ in
                    guard let selectedItem else { return }
                    if selectedItem == firstSelection {
                        proxy.scrollTo(Self.topID, anchor: .top)
                    } else {
                        proxy.scrollTo(selectedItem)
                    }
                }
            }
        }
        .onChange(of: colorScheme) { _, _ in icons.clear() }
    }

    private var firstSelection: LauncherSelection? {
        if mode == .applications, let section = applicationSections.first(where: { !$0.items.isEmpty }) {
            return LauncherSelection(sectionID: section.id, itemID: section.items[0].id)
        }
        if mode == .files, let section = fileSections.first(where: { !$0.items.isEmpty }) {
            return LauncherSelection(sectionID: section.id, itemID: section.items[0].id)
        }
        return nil
    }

    static func columnCount(for mode: CommandPaletteMode, width: CGFloat, style: LauncherViewStyle) -> Int {
        guard style == .grid else { return 1 }
        let cap = mode == .files ? 5 : 7
        let availableWidth = max(0, width - 40)
        return min(cap, max(1, Int((availableWidth + 10) / 100)))
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            if !chips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(chips) { chip in
                            Button {
                                onChipSelect(chip)
                            } label: {
                                Text(chip.title)
                                    .font(.system(size: 11, weight: .medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(chipBackgroundColor(for: chip), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selectedChipID == chip.id ? .isSelected : [])
                        }
                    }
                }
            }

            Spacer(minLength: 0)
            Menu {
                Button("Grid", systemImage: viewStyle == .grid ? "checkmark" : "square.grid.2x2") {
                    onViewStyleChange(.grid)
                }
                Button("List", systemImage: viewStyle == .list ? "checkmark" : "list.bullet") {
                    onViewStyleChange(.list)
                }
            } label: {
                Image(systemName: viewStyle == .grid ? "square.grid.2x2" : "list.bullet")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("View content as")
        }
        .frame(height: 30)
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private func applicationSection(
        _ section: LauncherSection<LauncherApplicationResult>,
        columnCount: Int
    ) -> some View {
        sectionHeading(section.title)
        if viewStyle == .grid {
            LazyVGrid(columns: columns(count: columnCount), spacing: 12) {
                ForEach(section.items) { item in
                    applicationCell(item, sectionID: section.id)
                }
            }
            .padding(.horizontal, 20)
        } else {
            LazyVStack(spacing: 2) {
                ForEach(section.items) { item in
                    applicationCell(item, sectionID: section.id)
                }
            }
            .padding(.horizontal, 12)
        }
    }

    @ViewBuilder
    private func fileSection(_ section: LauncherSection<LauncherFileResult>, columnCount: Int) -> some View {
        sectionHeading(section.title)
        if viewStyle == .grid {
            LazyVGrid(columns: columns(count: columnCount), spacing: 12) {
                ForEach(section.items) { item in
                    fileCell(item, sectionID: section.id)
                }
            }
            .padding(.horizontal, 20)
        } else {
            LazyVStack(spacing: 2) {
                ForEach(section.items) { item in
                    fileCell(item, sectionID: section.id)
                }
            }
            .padding(.horizontal, 12)
        }
    }

    @ViewBuilder
    private func sectionHeading(_ title: String) -> some View {
        if !title.isEmpty {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func applicationCell(_ item: LauncherApplicationResult, sectionID: LauncherSectionID) -> some View {
        let selection = LauncherSelection(sectionID: sectionID, itemID: item.id)
        let points: CGFloat = viewStyle == .grid ? 75 : 28
        let scale = NSApp.keyWindow?.backingScaleFactor ?? 2
        let taskID = IconTaskID(
            itemID: item.id,
            recordSequence: item.recordSequence,
            points: points,
            scale: scale,
            cacheGeneration: icons.cacheGeneration,
            requestGeneration: 0
        )
        return CommandPaletteLauncherCell(
            displayName: item.displayName,
            subtitle: item.categoryName,
            symbolName: "app.fill",
            image: icons.applicationIcon(for: item, points: points, scale: scale),
            viewStyle: viewStyle,
            isSelected: selectedItem == selection,
            nameLineLimit: 1,
            onSelect: { onSelect(selection) },
            onActivate: { onActivate(selection) }
        )
        .id(selection)
        .task(id: taskID) {
            icons.loadApplicationIcon(for: item, points: points, scale: scale)
        }
        .contextMenu {
            contextActions(
                for: selection,
                includesQuickLook: false,
                suggestedApplicationName: sectionID == .suggestions ? item.displayName : nil
            )
        }
    }

    private func fileCell(_ item: LauncherFileResult, sectionID: LauncherSectionID) -> some View {
        let selection = LauncherSelection(sectionID: sectionID, itemID: item.id)
        let points: CGFloat = viewStyle == .grid ? 75 : 28
        let scale = NSApp.keyWindow?.backingScaleFactor ?? 2
        let taskID = IconTaskID(
            itemID: item.id,
            recordSequence: 0,
            points: points,
            scale: scale,
            cacheGeneration: icons.cacheGeneration,
            requestGeneration: requestGeneration
        )
        return CommandPaletteLauncherCell(
            displayName: item.displayName,
            subtitle: fileSubtitle(item),
            symbolName: item.isDirectory ? "folder.fill" : "doc.fill",
            image: icons.fileThumbnail(for: item, points: points, scale: scale),
            viewStyle: viewStyle,
            isSelected: selectedItem == selection,
            nameLineLimit: 2,
            onSelect: { onSelect(selection) },
            onActivate: { onActivate(selection) }
        )
        .id(selection)
        .task(id: taskID) {
            icons.loadFileThumbnail(for: item, points: points, scale: scale)
        }
        .onChange(of: taskID) { previous, _ in
            if previous.points != taskID.points || previous.scale != taskID.scale {
                icons.cancelFileThumbnail(for: item, points: previous.points, scale: previous.scale)
            }
        }
        .onDisappear {
            icons.cancelFileThumbnail(for: item, points: points, scale: scale)
        }
        .contextMenu {
            contextActions(for: selection, includesQuickLook: true)
        }
    }

    @ViewBuilder
    private func contextActions(
        for selection: LauncherSelection,
        includesQuickLook: Bool,
        suggestedApplicationName: String? = nil
    ) -> some View {
        Button("Open") { onContextAction(selection, .open) }
        Button("Show in Finder") { onContextAction(selection, .reveal) }
        if includesQuickLook {
            Button("Quick Look") { onContextAction(selection, .quickLook) }
        }
        Divider()
        Button("Copy") { onContextAction(selection, .copy) }
        Button("Copy Path") { onContextAction(selection, .copyPath) }
        if let suggestedApplicationName {
            Divider()
            Button(String(localized: "Don’t Suggest “\(suggestedApplicationName)”")) {
                onContextAction(selection, .dontSuggest)
            }
        }
    }

    private func fileSubtitle(_ item: LauncherFileResult) -> String? {
        if showsPaths { return item.fileURL.path }
        if let modifiedAt = item.modifiedAt {
            return String(localized: "Modified \(modifiedAt.formatted(date: .abbreviated, time: .omitted))")
        }
        return item.kind
    }

    private func columns(count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 0), spacing: 10), count: count)
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 48)
    }

    private func chipBackgroundColor(for chip: LauncherChip) -> Color {
        selectedChipID == chip.id ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12)
    }
}
