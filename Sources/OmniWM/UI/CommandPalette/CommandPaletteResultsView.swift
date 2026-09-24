// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Observation
import SwiftUI

struct CommandPaletteResultsView: View {
    @Bindable var controller: CommandPaletteController
    @Bindable var motionPolicy: MotionPolicy

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    paletteRows
                }
                .padding(.vertical, 8)
            }
            .onChange(of: controller.selectionScrollRequest) { _, _ in
                if let selectedItemID = controller.selectedItemID {
                    if motionPolicy.animationsEnabled {
                        withAnimation(.easeInOut(duration: 0.1)) {
                            proxy.scrollTo(selectedItemID)
                        }
                    } else {
                        proxy.scrollTo(selectedItemID)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var paletteRows: some View {
        switch controller.selectedMode {
        case .windows:
            ForEach(controller.filteredWindowItems) { item in
                CommandPaletteWindowRow(
                    item: item,
                    isSelected: controller.selectedItemID == .window(item.id),
                    isSummonRightAvailable: controller.isSummonRightAvailable
                        && CommandPalettePresentation.allowsSummonRight(item),
                    onSelect: {
                        controller.selectedItemID = .window(item.id)
                        controller.selectCurrent()
                    }
                )
                .id(CommandPaletteSelectionID.window(item.id))
            }
        case .menu:
            ForEach(controller.filteredMenuItems) { item in
                CommandPaletteMenuRow(
                    item: item,
                    isSelected: controller.selectedItemID == .menu(item.id)
                )
                .id(CommandPaletteSelectionID.menu(item.id))
                .onTapGesture {
                    controller.selectedItemID = .menu(item.id)
                    controller.selectCurrent()
                }
            }
        case .clipboard:
            ForEach(controller.filteredClipboardItems) { item in
                CommandPaletteClipboardRow(
                    item: item,
                    isSelected: controller.selectedItemID == .clipboard(item.id),
                    onCopy: {
                        controller.selectedItemID = .clipboard(item.id)
                        controller.selectCurrent()
                    },
                    onPaste: {
                        controller.selectedItemID = .clipboard(item.id)
                        controller.selectCurrent(trigger: .alternate)
                    },
                    onPasteWithoutFormatting: {
                        controller.pasteClipboardItem(item.id, withoutFormatting: true)
                    },
                    onPin: {
                        controller.setClipboardItemPinned(!item.isPinned, id: item.id)
                    },
                    onDelete: {
                        controller.deleteClipboardItem(item.id)
                    },
                    onHighlight: {
                        controller.selectedItemID = .clipboard(item.id)
                    }
                )
                .id(CommandPaletteSelectionID.clipboard(item.id))
            }
        case .commands:
            if controller.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ForEach(HotkeyCategory.allCases, id: \.self) { category in
                    let items = controller.commandItems.filter { $0.spec.category == category }
                    if !items.isEmpty {
                        Text(category.localizedDisplayName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                            .padding(.bottom, 4)
                            .accessibilityAddTraits(.isHeader)
                        commandRows(items, showsCategory: false)
                    }
                }
            } else {
                commandRows(controller.filteredCommandItems, showsCategory: true)
            }
        }
    }

    private func commandRows(
        _ items: [CommandPaletteCommandItem],
        showsCategory: Bool
    ) -> some View {
        ForEach(items, id: \.id) { item in
            CommandPaletteCommandRow(
                item: item,
                isSelected: controller.selectedItemID == .command(item.id),
                showsCategory: showsCategory,
                onSelect: {
                    guard item.isLayoutCompatible else { return }
                    controller.selectedItemID = .command(item.id)
                    controller.selectCurrent()
                }
            )
            .id(CommandPaletteSelectionID.command(item.id))
        }
    }
}
