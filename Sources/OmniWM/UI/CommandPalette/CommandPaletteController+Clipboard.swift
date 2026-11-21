// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
extension CommandPaletteController {
    func setClipboardItemPinned(_ pinned: Bool, id: UUID) {
        guard let wmController, isClipboardHistoryEnabled,
              environment.isClipboardHistoryEnabled(wmController)
        else { return }
        Task { @MainActor [weak self, environment, wmController] in
            let items = await environment.setClipboardItemPinned(wmController, id, pinned)
            guard let self, self.isVisible, environment.isClipboardHistoryEnabled(wmController) else { return }
            self.clipboardErrorText = nil
            self.clipboardItems = items
        }
    }

    func deleteClipboardItem(_ id: UUID) {
        guard let wmController, isClipboardHistoryEnabled,
              environment.isClipboardHistoryEnabled(wmController)
        else { return }
        Task { @MainActor [weak self, environment, wmController] in
            let items = await environment.deleteClipboardItem(wmController, id)
            guard let self, self.isVisible, environment.isClipboardHistoryEnabled(wmController) else { return }
            self.clipboardItems = items
            self.clipboardErrorText = nil
        }
    }

    func clearClipboardHistory() {
        guard let wmController, isClipboardHistoryEnabled,
              environment.isClipboardHistoryEnabled(wmController)
        else { return }
        isConfirmingClipboardClear = true
        defer { isConfirmingClipboardClear = false }
        guard environment.confirmClearClipboardHistory() else { return }
        Task { @MainActor [weak self, environment, wmController] in
            do {
                let items = try await environment.clearClipboardHistory(wmController)
                guard let self, self.isVisible, environment.isClipboardHistoryEnabled(wmController) else { return }
                self.clipboardItems = items
                self.clipboardErrorText = nil
            } catch {
                guard let self, self.isVisible, environment.isClipboardHistoryEnabled(wmController) else { return }
                self.clipboardErrorText = String(localized: "Could not clear clipboard history.")
            }
        }
    }

    func enableClipboardHistory() {
        guard let wmController else { return }
        environment.setClipboardHistoryEnabled(wmController, true)
        isClipboardHistoryEnabled = true
        refreshClipboardItems()
    }

    func refreshClipboardItems() {
        guard let wmController else {
            clipboardItems = []
            return
        }
        isClipboardHistoryEnabled = environment.isClipboardHistoryEnabled(wmController)
        clipboardItems = isClipboardHistoryEnabled ? environment.clipboardItems(wmController) : []
    }

    func loadSelectedClipboardPreview() {
        clipboardPreviewGeneration &+= 1
        let generation = clipboardPreviewGeneration
        clipboardPreview = nil
        clipboardPreviewImage = nil
        isClipboardPreviewLoading = false
        guard isVisible,
              !isUnifiedSearch,
              selectedMode == .clipboard,
              let wmController,
              case let .clipboard(id)? = selectedItemID
        else {
            return
        }
        isClipboardPreviewLoading = true
        Task { @MainActor [weak self, environment, wmController] in
            let preview = await environment.clipboardItemPreview(wmController, id)
            guard let self,
                  self.isVisible,
                  self.clipboardPreviewGeneration == generation,
                  self.selectedItemID == .clipboard(id)
            else {
                return
            }
            self.clipboardPreview = preview
            if case let .image(data)? = preview {
                self.clipboardPreviewImage = NSImage(data: data)
            }
            self.isClipboardPreviewLoading = false
        }
    }
}
