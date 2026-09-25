// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon

@MainActor
extension CommandPaletteController {
    func handleLauncherKeyDown(_ event: NSEvent, relevantModifiers: NSEvent.ModifierFlags) -> Bool {
        if handleLauncherScopeKey(event, modifiers: relevantModifiers) { return true }
        if handleLauncherPreviewKey(event, modifiers: relevantModifiers) { return true }
        if handleLauncherRevealKey(event, modifiers: relevantModifiers) { return true }
        guard isLauncherMode else { return false }

        if event.keyCode == UInt16(kVK_Delete),
           relevantModifiers.isEmpty,
           searchText.isEmpty,
           selectedLauncherChipID != nil
        {
            clearLauncherChip()
            return true
        }

        return handleLauncherNavigationKey(event, modifiers: relevantModifiers)
    }

    private func handleLauncherScopeKey(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard isLauncherMode, searchText == "/", modifiers.isEmpty, !launcherChips.isEmpty else { return false }
        if event.keyCode == UInt16(kVK_LeftArrow) || event.keyCode == UInt16(kVK_RightArrow) {
            let direction = event.keyCode == UInt16(kVK_LeftArrow) ? -1 : 1
            launcherScopeChipIndex = min(max(launcherScopeChipIndex + direction, 0), launcherChips.count - 1)
            return true
        }
        guard [UInt16(kVK_Tab), UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter)].contains(event.keyCode) else {
            return false
        }
        let chip = launcherChips[min(launcherScopeChipIndex, launcherChips.count - 1)]
        if selectedMode == .applications {
            selectedApplicationChip = chip
        } else {
            selectedFileChip = chip
        }
        searchText = ""
        return true
    }

    private func handleLauncherPreviewKey(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard selectedMode == .files else { return false }
        if isLauncherPreviewVisible, event.keyCode == UInt16(kVK_Escape) {
            isLauncherPreviewVisible = false
            return true
        }
        let commandPreview = modifiers == .command && event.charactersIgnoringModifiers?.lowercased() == "y"
        let focusedPreview = modifiers.isEmpty && event.keyCode == UInt16(kVK_Space) && launcherResultsFocused
        guard commandPreview || focusedPreview else { return false }
        if isLauncherPreviewVisible || selectedLauncherFileResult != nil {
            isLauncherPreviewVisible.toggle()
        }
        return true
    }

    private func handleLauncherRevealKey(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard modifiers == .command,
              [UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter)].contains(event.keyCode)
              || event.charactersIgnoringModifiers?.lowercased() == "r"
        else {
            return false
        }
        selectCurrent(trigger: .reveal)
        return true
    }

    private func handleLauncherNavigationKey(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard modifiers.isEmpty else { return false }

        switch event.keyCode {
        case UInt16(kVK_UpArrow):
            launcherResultsFocused = true
            moveLauncherSelection(horizontal: 0, vertical: -1)
            return true
        case UInt16(kVK_DownArrow):
            launcherResultsFocused = true
            moveLauncherSelection(horizontal: 0, vertical: 1)
            return true
        case UInt16(kVK_LeftArrow) where launcherResultsFocused:
            moveLauncherSelection(horizontal: -1, vertical: 0)
            return true
        case UInt16(kVK_RightArrow) where launcherResultsFocused:
            moveLauncherSelection(horizontal: 1, vertical: 0)
            return true
        default:
            return false
        }
    }

    private func moveLauncherSelection(horizontal: Int, vertical: Int) {
        expandResults()
        let selectionList = currentSelectionList()
        guard !selectionList.isEmpty else { return }
        let ranges = launcherSectionRanges()
        let currentIndex = selectedItemID.flatMap { selectionList.firstIndex(of: $0) } ?? 0
        guard let rangeIndex = ranges.firstIndex(where: {
            currentIndex >= $0.start && currentIndex < $0.start + $0.count
        }) else {
            selectedItemID = selectionList.first
            return
        }

        let range = ranges[rangeIndex]
        let columns = max(1, launcherColumnCount)
        let localIndex = currentIndex - range.start
        let column = localIndex % columns
        let targetIndex: Int
        if horizontal < 0, column > 0 {
            targetIndex = currentIndex - 1
        } else if horizontal > 0, column < columns - 1, localIndex + 1 < range.count {
            targetIndex = currentIndex + 1
        } else {
            targetIndex = verticalLauncherTargetIndex(
                ranges: ranges,
                rangeIndex: rangeIndex,
                currentIndex: currentIndex,
                direction: vertical
            )
        }

        if targetIndex != currentIndex || selectedItemID == nil {
            selectedItemID = selectionList[targetIndex]
            selectionScrollRequest &+= 1
        }
    }

    private func verticalLauncherTargetIndex(
        ranges: [(start: Int, count: Int)],
        rangeIndex: Int,
        currentIndex: Int,
        direction: Int
    ) -> Int {
        let range = ranges[rangeIndex]
        let columns = max(1, launcherColumnCount)
        let localIndex = currentIndex - range.start
        let row = localIndex / columns
        let column = localIndex % columns
        if direction < 0 {
            if row > 0 { return currentIndex - columns }
            guard rangeIndex > 0 else { return currentIndex }
            let previous = ranges[rangeIndex - 1]
            let previousLastRow = (previous.count - 1) / columns
            return previous.start + min(previousLastRow * columns + column, previous.count - 1)
        }
        if direction > 0 {
            if row < (range.count - 1) / columns {
                return range.start + min(localIndex + columns, range.count - 1)
            }
            guard rangeIndex + 1 < ranges.count else { return currentIndex }
            let next = ranges[rangeIndex + 1]
            return next.start + min(column, next.count - 1)
        }
        return currentIndex
    }

    private func launcherSectionRanges() -> [(start: Int, count: Int)] {
        let counts = selectedMode == .applications
            ? applicationSections.map(\.items.count)
            : fileSections.map(\.items.count)
        var start = 0
        return counts.compactMap { count in
            guard count > 0 else { return nil }
            defer { start += count }
            return (start: start, count: count)
        }
    }
}
