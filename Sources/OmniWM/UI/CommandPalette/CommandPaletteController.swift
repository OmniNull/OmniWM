// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Carbon
import Observation
import SwiftUI

@MainActor
@Observable
final class CommandPaletteController: NSObject, NSWindowDelegate {
    private(set) var isVisible = false
    private(set) var isExpanded = false
    var actionFeedbackText: String?
    var searchText = "" {
        didSet {
            if searchText != oldValue { actionFeedbackText = nil }
            if isVisible, isLauncherMode {
                launcherSearchTextDidChange(from: oldValue)
            } else {
                if selectedMode == .windows, searchText != oldValue {
                    selectedItemID = nil
                }
                updateSelectionAfterFilterChange()
            }
            if !searchText.isEmpty {
                expandResults()
            }
        }
    }

    var selectedMode: CommandPaletteMode = .windows {
        didSet { handleModeChange(from: oldValue) }
    }

    var selectedItemID: CommandPaletteSelectionID? {
        didSet {
            if selectedItemID != oldValue {
                actionFeedbackText = nil
                loadSelectedClipboardPreview()
            }
        }
    }

    var windows: [CommandPaletteWindowItem] = [] {
        didSet { updateSelectionAfterFilterChange() }
    }

    private(set) var menuItems: [MenuItemModel] = [] {
        didSet { updateSelectionAfterFilterChange() }
    }

    private(set) var isMenuLoading = false
    private(set) var clipboardItems: [ClipboardPaletteItem] = [] {
        didSet { updateSelectionAfterFilterChange() }
    }

    private(set) var commandItems: [CommandPaletteCommandItem] = [] {
        didSet { updateSelectionAfterFilterChange() }
    }

    private(set) var isClipboardHistoryEnabled = false
    private(set) var clipboardPreview: ClipboardPalettePreview?
    private(set) var clipboardPreviewImage: NSImage?
    private(set) var isClipboardPreviewLoading = false
    private(set) var clipboardErrorText: String?
    var selectionScrollRequest = 0

    var applicationSections: [LauncherSection<LauncherApplicationResult>] = []
    var fileSections: [LauncherSection<LauncherFileResult>] = []
    var applicationChips: [LauncherChip] = []
    var fileChips: [LauncherChip] = []
    var selectedApplicationChip: LauncherChip?
    var selectedFileChip: LauncherChip?
    var applicationViewStyle: LauncherViewStyle = .grid
    var fileViewStyle: LauncherViewStyle = .grid
    var isApplicationLoading = false
    var isFileLoading = false
    var launcherColumnCount = 1
    var launcherScopeChipIndex = 0
    var launcherResultsFocused = false
    var launcherShowsPaths = false
    var isLauncherPreviewVisible = false
    var launcherRequestGeneration = 0
    var launcherPublishedGeneration = -1
    var pendingLauncherSelection: (generation: Int, trigger: CommandPaletteSelectionTrigger)?

    let environment: CommandPaletteEnvironment
    let presentation: CommandPalettePanel
    private var eventMonitor: Any?

    weak var wmController: WMController?
    let focusSession: CommandPaletteFocusSession
    let actionExecutor: CommandPaletteActionExecutor
    private let menuSession: CommandPaletteMenuSession
    private var isProgrammaticDismiss = false
    private var isConfirmingClipboardClear = false
    var isPresentingMarkPrompt = false
    private var clipboardPreviewGeneration = 0

    enum DismissReason {
        case cancel
        case selection
        case deactivation
        case superseded
    }

    init(
        motionPolicy: MotionPolicy,
        environment: CommandPaletteEnvironment = .init(),
        ownedWindowRegistry: OwnedWindowRegistry = .shared
    ) {
        self.environment = environment
        menuSession = CommandPaletteMenuSession(environment: environment)
        let focusSession = CommandPaletteFocusSession(environment: environment)
        self.focusSession = focusSession
        actionExecutor = CommandPaletteActionExecutor(environment: environment, focusSession: focusSession)
        presentation = CommandPalettePanel(motionPolicy: motionPolicy, ownedWindowRegistry: ownedWindowRegistry)
        super.init()
    }

    var isCurrentWorkspaceEmpty: Bool {
        guard let wmController, let workspaceId = focusSession.workspaceId else { return false }
        return wmController.workspaceManager.windowCount(in: workspaceId) == 0
    }

    func toggle(wmController: WMController, mode: CommandPaletteMode? = nil) {
        guard isVisible else {
            show(wmController: wmController, mode: mode)
            return
        }
        if let mode, mode != selectedMode {
            selectedMode = mode
        } else {
            dismiss(reason: .cancel)
        }
    }

    func show(wmController: WMController, mode: CommandPaletteMode? = nil) {
        actionExecutor.cancelPendingCommand()
        if isVisible {
            dismiss(reason: .superseded)
        }

        self.wmController = wmController

        focusSession.begin(wmController: wmController)
        windows = CommandPaletteSearch.buildWindowItems(
            from: wmController, focusedWindow: focusSession.restoreFocusTarget
        )
        menuItems = []
        isClipboardHistoryEnabled = environment.isClipboardHistoryEnabled(wmController)
        clipboardItems = isClipboardHistoryEnabled ? environment.clipboardItems(wmController) : []
        clipboardErrorText = nil
        commandItems = CommandPaletteSearch.buildCommandItems(from: wmController)
        menuSession.resetCache()
        isMenuLoading = false
        resetLauncherState(settings: wmController.settings)
        searchText = ""
        selectedItemID = nil
        menuSession.invalidate()

        if presentation.panel == nil {
            presentation.create(controller: self)
        }

        guard let panel = presentation.panel else { return }

        presentation.position(panel)
        isExpanded = false

        let preferredMode = mode ?? wmController.settings.commandPaletteLastMode
        selectedMode = resolvedInitialMode(preferredMode)

        installEventMonitor()

        isVisible = true
        wmController.focusPolicyEngine.beginLease(owner: .commandPalette, reason: "command_palette", duration: nil)
        environment.observeClipboardItems(wmController) { [weak self] items in
            guard let self, self.isVisible else { return }
            self.isClipboardHistoryEnabled = self.environment.isClipboardHistoryEnabled(wmController)
            self.clipboardItems = self.isClipboardHistoryEnabled ? items : []
        }
        updateSelectionAfterFilterChange()
        loadSelectedClipboardPreview()
        panel.orderFrontRegardless()
        panel.makeKey()
        presentation.reveal(panel)

        if selectedMode == .menu {
            loadMenuItemsIfNeeded()
        } else if isLauncherMode {
            expandResults()
            startLauncherSearch()
        }
    }

    func windowDidResignKey(_: Notification) {
        guard isVisible, !isProgrammaticDismiss, !isConfirmingClipboardClear, !isPresentingMarkPrompt else {
            return
        }
        dismiss(reason: .deactivation)
    }

    private func handleModeChange(from oldValue: CommandPaletteMode) {
        guard selectedMode != oldValue else { return }
        guard isModeAvailable(selectedMode) else {
            selectedMode = .windows
            return
        }
        invalidateLauncherSearch()
        launcherResultsFocused = false
        selectedItemID = nil
        expandResults()
        wmController?.settings.commandPaletteLastMode = selectedMode
        if selectedMode == .menu {
            loadMenuItemsIfNeeded()
        } else if selectedMode == .clipboard {
            refreshClipboardItems()
        } else if isLauncherMode {
            startLauncherSearch()
        }
        updateSelectionAfterFilterChange()
    }

    private func loadMenuItemsIfNeeded() {
        guard isVisible, selectedMode == .menu else { return }
        guard isMenuModeAvailable else {
            menuItems = []
            isMenuLoading = false
            return
        }
        menuSession.load(target: focusSession.menuFocusTarget, canStart: { [weak self] in
            self?.isVisible == true && self?.selectedMode == .menu
        }, canPublish: { [weak self] in
            self?.isVisible == true
        }, publish: { [weak self] publication in
            guard let self else { return }
            switch publication {
            case .loading:
                self.isMenuLoading = true
                self.menuItems = []
            case let .loaded(items):
                self.menuItems = items
                self.isMenuLoading = false
            }
        })
    }

    func dismissForLauncherSelection() {
        dismiss(reason: .selection)
    }

    func selectMode(_ mode: CommandPaletteMode) {
        selectedMode = mode
        expandResults()
    }

    func expandResults() {
        guard isVisible, !isExpanded, let panel = presentation.panel else { return }
        if presentation.animatesPresentation {
            withAnimation(.easeOut(duration: CommandPalettePanel.expansionDuration)) {
                isExpanded = true
            }
        } else {
            isExpanded = true
        }
        presentation.expand(panel)
    }

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

    private func loadSelectedClipboardPreview() {
        clipboardPreviewGeneration &+= 1
        let generation = clipboardPreviewGeneration
        clipboardPreview = nil
        clipboardPreviewImage = nil
        isClipboardPreviewLoading = false
        guard isVisible,
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

extension CommandPaletteController {
    func dismiss(reason: DismissReason) {
        removeEventMonitor()
        invalidateLauncherSearch()
        isVisible = false
        clipboardPreviewGeneration &+= 1
        clipboardPreview = nil
        clipboardPreviewImage = nil
        isClipboardPreviewLoading = false
        isMenuLoading = false
        menuSession.invalidate()
        if let wmController {
            environment.observeClipboardItems(wmController, nil)
            wmController.focusPolicyEngine.endLease(owner: .commandPalette)
        }

        var defersContentClear = false
        if let panel = presentation.panel {
            presentation.rememberPlacement(panel, expanded: isExpanded)
            isProgrammaticDismiss = true
            if case .cancel = reason, presentation.animatesPresentation {
                defersContentClear = true
                withAnimation(.easeOut(duration: CommandPalettePanel.dismissalDuration)) {
                    isExpanded = false
                }
                presentation.dismiss(panel) { [weak self] in
                    self?.clearPresentedContent()
                }
            } else {
                panel.orderOut(nil)
                isExpanded = false
            }
            isProgrammaticDismiss = false
        }

        let restoreTarget = reason == .cancel ? focusSession.restoreFocusTarget : nil

        focusSession.clear()
        wmController = nil
        if !defersContentClear {
            clearPresentedContent()
        }

        if let restoreTarget {
            _ = focusSession.focus(target: restoreTarget)
        }
    }

    private func clearPresentedContent() {
        menuSession.resetCache()
        actionFeedbackText = nil
        searchText = ""
        selectedItemID = nil
        windows = []
        menuItems = []
        clipboardItems = []
        commandItems = []
        isClipboardHistoryEnabled = false
    }

    private func installEventMonitor() {
        removeEventMonitor()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, isVisible, !isPresentingMarkPrompt else { return event }
            return handleKeyDown(event) ? nil : event
        }
    }

    private func removeEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    func restoreKeyWindowAfterMarkPrompt() {
        if isVisible {
            presentation.panel?.makeKey()
        }
    }
}

extension CommandPaletteController {
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
}
