// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
import Foundation

@MainActor
final class OverviewInputHandler {
    enum KeyAction: Equatable {
        case dismissSelection
        case activateSelection
        case closeSelection
        case navigate(Direction)
        case cycleSelection(forward: Bool)
        case deleteBackward
        case appendToSearch(String)
        case consume
    }

    struct KeyHandlingResult: Equatable {
        let action: KeyAction
        let shouldConsume: Bool
    }

    private enum KeyCode {
        static let escape = UInt16(kVK_Escape)
        static let returnKey = UInt16(kVK_Return)
        static let keypadEnter = UInt16(kVK_ANSI_KeypadEnter)
        static let leftArrow = UInt16(kVK_LeftArrow)
        static let rightArrow = UInt16(kVK_RightArrow)
        static let downArrow = UInt16(kVK_DownArrow)
        static let upArrow = UInt16(kVK_UpArrow)
        static let tab = UInt16(kVK_Tab)
        static let delete = UInt16(kVK_Delete)
        static let closeWindow = UInt16(kVK_ANSI_W)
    }

    private var gestureScrollGate = OverviewScrollInput.GestureScrollGate()
    private weak var controller: OverviewController?
    private let projection: OverviewViewportProjection
    private let windowSession: OverviewWindowSession
    private let overviewSnapshot: OverviewSnapshot
    private var state: OverviewState {
        controller?.state ?? .closed
    }

    var searchQuery: String {
        get { projection.searchQuery }
        set { projection.searchQuery = newValue }
    }

    init(
        projection: OverviewViewportProjection,
        windowSession: OverviewWindowSession,
        snapshot: OverviewSnapshot
    ) {
        self.projection = projection
        self.windowSession = windowSession
        overviewSnapshot = snapshot
    }

    func connect(controller: OverviewController) {
        self.controller = controller
    }

    private func updateWindowDisplays(update: OverviewLayoutUpdate = .preserve, on monitorId: Monitor.ID? = nil) {
        windowSession.updateWindowDisplays(state: state, update: update, on: monitorId)
    }

    func handleMagnification(_ event: NSEvent) -> Bool {
        guard let point = controller?.wmController?.currentMouseLocation() else { return false }
        return windowSession.magnify(with: event, at: point)
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let controller else { return false }
        guard controller.state.isOpen else { return false }
        guard !windowSession.isTabPickerOpen else { return false }

        let result = Self.keyHandlingResult(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            searchQuery: searchQuery,
            isRepeat: event.isARepeat
        )
        guard result.shouldConsume else { return false }

        switch controller.state {
        case .closed:
            return false
        case .closing:
            return true
        case .opening:
            switch result.action {
            case .dismissSelection:
                dismissToSelection(animated: true)
            case .activateSelection:
                dismissToSelection(animated: true)
            case .closeSelection,
                 .navigate,
                 .cycleSelection,
                 .deleteBackward,
                 .appendToSearch,
                 .consume:
                break
            }
            return true
        case .open:
            break
        }

        performAction(result.action, controller: controller)
        return true
    }

    private func performAction(_ action: KeyAction, controller: OverviewController) {
        switch action {
        case .dismissSelection:
            dismissToSelection(animated: true)
        case .activateSelection:
            activateSelectedWindow()
        case .closeSelection:
            closeSelectedWindow()
        case let .navigate(direction):
            navigateSelection(direction)
        case let .cycleSelection(forward):
            cycleSelection(forward: forward)
        case .deleteBackward:
            if !searchQuery.isEmpty {
                searchQuery = String(searchQuery.dropLast())
                updateSearchQuery(searchQuery)
            }
        case let .appendToSearch(text):
            searchQuery += text
            updateSearchQuery(searchQuery)
        case .consume:
            break
        }
    }

    static func keyHandlingResult(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?,
        searchQuery _: String,
        isRepeat: Bool = false
    ) -> KeyHandlingResult {
        let relevantModifiers = modifierFlags.intersection([.shift, .command, .control, .option])

        if relevantModifiers == .command,
           KeyEquivalent.matches(
               "w",
               ansiKeyCode: Int(KeyCode.closeWindow),
               keyCode: keyCode,
               charactersIgnoringModifiers: charactersIgnoringModifiers
           )
        {
            guard !isRepeat else { return .init(action: .consume, shouldConsume: true) }
            return .init(action: .closeSelection, shouldConsume: true)
        }

        switch keyCode {
        case KeyCode.escape:
            guard !isRepeat else { return .init(action: .consume, shouldConsume: true) }
            return .init(action: .dismissSelection, shouldConsume: true)
        case KeyCode.returnKey,
             KeyCode.keypadEnter:
            guard relevantModifiers.isEmpty else { break }
            guard !isRepeat else { return .init(action: .consume, shouldConsume: true) }
            return .init(action: .activateSelection, shouldConsume: true)
        case KeyCode.leftArrow,
             KeyCode.rightArrow,
             KeyCode.downArrow,
             KeyCode.upArrow:
            guard relevantModifiers.isEmpty, let direction = navigationDirection(for: keyCode) else { break }
            return .init(action: .navigate(direction), shouldConsume: true)
        case KeyCode.tab:
            guard relevantModifiers.isEmpty || relevantModifiers == .shift else { break }
            return .init(
                action: .cycleSelection(forward: !relevantModifiers.contains(.shift)),
                shouldConsume: true
            )
        case KeyCode.delete:
            guard relevantModifiers.isEmpty else { break }
            return .init(action: .deleteBackward, shouldConsume: true)
        default:
            break
        }

        if relevantModifiers.isDisjoint(with: [.command, .control, .option]),
           let charactersIgnoringModifiers,
           let character = charactersIgnoringModifiers.first,
           charactersIgnoringModifiers.count == 1,
           character.isLetter || character.isNumber || character == " "
        {
            return .init(action: .appendToSearch(String(character)), shouldConsume: true)
        }

        return .init(action: .consume, shouldConsume: true)
    }

    private static func navigationDirection(for keyCode: UInt16) -> Direction? {
        switch keyCode {
        case KeyCode.leftArrow: .left
        case KeyCode.rightArrow: .right
        case KeyCode.downArrow: .down
        case KeyCode.upArrow: .up
        default: nil
        }
    }

    func beginGestureScrollSuppression() {
        gestureScrollGate.awaitingNewGesture = true
    }

    func reset() {
        gestureScrollGate = OverviewScrollInput.GestureScrollGate()
        searchQuery = ""
    }
}

extension OverviewInputHandler {
    func handleHotkeyInvocation(_ invocation: HotkeyInvocation) -> OverviewHotkeyDisposition {
        guard state.isOpen else { return .inactive }
        guard !windowSession.isTabPickerOpen else { return .blocked }
        if let trigger = invocation.trigger,
           let action = Self.physicalHotkeyAction(for: trigger)
        {
            guard !trigger.isRepeat else { return .handled }
            switch action {
            case .dismissSelection:
                dismissToSelection(animated: true)
            case .activateSelection:
                if case .opening = state {
                    dismissToSelection(animated: true)
                } else {
                    activateSelectedWindow()
                }
            case .closeSelection:
                closeSelectedWindow()
            }
            return .handled
        }
        return handleHotkeyCommand(invocation.command)
    }

    static func physicalHotkeyAction(for trigger: PhysicalHotkeyTrigger) -> OverviewPhysicalHotkeyAction? {
        let relevantModifiers = trigger.modifiers
            & UInt32(controlKey | optionKey | shiftKey | cmdKey)
        switch trigger.keyCode {
        case UInt32(kVK_Escape):
            return .dismissSelection
        case UInt32(kVK_Return),
             UInt32(kVK_ANSI_KeypadEnter):
            return relevantModifiers == 0 ? .activateSelection : nil
        case UInt32(kVK_ANSI_W):
            return relevantModifiers == UInt32(cmdKey) ? .closeSelection : nil
        default:
            return nil
        }
    }

    func handleHotkeyCommand(_ command: HotkeyCommand) -> OverviewHotkeyDisposition {
        guard state.isOpen else { return .inactive }
        guard !windowSession.isTabPickerOpen else { return .blocked }

        switch command {
        case .presentation(.overview):
            controller?.toggle()
            return .handled
        case let .focus(direction):
            guard case .open = state, controller?.hasActiveDragSession == false else { return .handled }
            navigateSelection(direction)
            return .handled
        default:
            guard OverviewStructuralActions.isStructuralHotkey(command) else { return .blocked }
            guard case .open = state,
                  controller?.hasActiveDragSession == false,
                  controller?.canPerformStructuralHotkey == true
            else {
                return .handled
            }
            guard let selectedWindowHandle = projection.selectedWindowHandle else { return .handled }
            controller?.executeStructuralHotkey(command, selectedHandle: selectedWindowHandle)
            return .handled
        }
    }

    func selectTab(_ handle: WindowHandle, on monitorId: Monitor.ID) {
        guard case .open = state, controller?.hasActiveDragSession == false,
              projection.layoutsByMonitor[monitorId]?.window(for: handle)?.matchesSearch == true
        else { return }
        projection.activeInteractionMonitorId = monitorId
        projection.setSelectedWindowHandle(handle)
        projection.revealSelectedWindow(on: monitorId)
        updateWindowDisplays()
    }

    func panStrip(at point: CGPoint, by delta: CGFloat, on monitorId: Monitor.ID) {
        guard case .open = state, controller?.hasActiveDragSession == false,
              let section = projection.layoutsByMonitor[monitorId]?.ribbonSection(at: point)
        else { return }
        projection.panStrip(section.workspaceId, by: delta, on: monitorId)
        updateWindowDisplays(update: .immediate, on: monitorId)
    }

    func selectAndActivateWindow(_ handle: WindowHandle) {
        guard case .open = state else { return }
        projection.setSelectedWindowHandle(handle)
        controller?.dismiss(reason: .selection, targetWindow: handle, animated: true)
    }

    func updateSearchQuery(_ query: String) {
        searchQuery = query
        projection.rebuildProjectedLayouts(revealingSelection: false)
        updateWindowDisplays()
    }

    func navigateSelection(_ direction: Direction, on monitorId: Monitor.ID? = nil) {
        guard case .open = state else { return }
        let result = projection.performSelectionNavigation(on: monitorId) { layout, selection in
            OverviewNavigation.nextSelection(
                in: layout,
                from: selection,
                direction: direction,
                searching: !searchQuery.isEmpty
            )
        }
        if result.changed {
            updateWindowDisplays(
                update: result.revealed ? .viewport : .preserve,
                on: projection.activeInteractionMonitorId
            )
        }
    }

    func cycleSelection(forward: Bool, on monitorId: Monitor.ID? = nil) {
        guard case .open = state else { return }
        let result = projection.performSelectionNavigation(on: monitorId) { layout, selection in
            OverviewNavigation.cycledSelection(
                in: layout,
                from: selection,
                forward: forward,
                searching: !searchQuery.isEmpty
            )
        }
        if result.changed {
            updateWindowDisplays(
                update: result.revealed ? .viewport : .preserve,
                on: projection.activeInteractionMonitorId
            )
        }
    }

    func activateSelectedWindow() {
        guard case .open = state, let selection = projection.selection else { return }
        switch selection {
        case let .window(handle): selectAndActivateWindow(handle)
        case let .workspace(id): controller?.activateWorkspace(id)
        case let .newWorkspace(id): controller?.createWorkspace(on: id)
        }
    }

    func selectionDismissal() -> (reason: OverviewController.OverviewDismissReason, targetWindow: WindowHandle?) {
        guard let selectedWindowHandle = projection.selectedWindowHandle,
              overviewSnapshot.windows[selectedWindowHandle] != nil
        else { return (.cancel, nil) }
        return (.selection, selectedWindowHandle)
    }

    func dismissToSelection(animated: Bool) {
        let dismissal = selectionDismissal()
        controller?.dismiss(reason: dismissal.reason, targetWindow: dismissal.targetWindow, animated: animated)
    }

    func closeSelectedWindow() {
        guard case .open = state, let selectedWindowHandle = projection.selectedWindowHandle else { return }
        controller?.closeWindow(selectedWindowHandle)
    }

    func adjustScrollOffset(by delta: CGFloat, on monitorId: Monitor.ID) {
        projection.adjustScrollOffset(by: delta, on: monitorId)
        updateWindowDisplays(update: .immediate, on: monitorId)
    }

    func handleScroll(_ event: OverviewScrollInput.Event, on monitorId: Monitor.ID) {
        let suppressed = gestureScrollGate.consumes(event, state: state)
        let tracing = TrackpadScrollTrace.shared.isActive
        let before = tracing ? projection.layoutsByMonitor[monitorId]?.scrollOffset : nil
        defer {
            if tracing {
                TrackpadScrollTrace.record(.overviewScroll(
                    phase: event.phase.rawValue, momentum: event.momentumPhase.rawValue, precise: event.isPrecise,
                    state: String(describing: state), suppressed: suppressed,
                    before: before.map { Double($0) },
                    after: projection.layoutsByMonitor[monitorId].map { Double($0.scrollOffset) }
                ))
            }
        }
        guard !suppressed else { return }
        let zoom = event.modifiers.contains([.option, .shift])
        let immediate = event.isPrecise || zoom
        if projection.handleScroll(event, on: monitorId) || immediate {
            updateWindowDisplays(update: immediate ? .immediate : .viewport, on: zoom ? nil : monitorId)
        }
    }

    func pageStrip(_ pill: OverviewOverflowPill, on monitorId: Monitor.ID) {
        guard case .open = state else { return }
        if projection.pageStrip(pill, on: monitorId) {
            updateWindowDisplays(update: .viewport, on: monitorId)
        }
    }
}
