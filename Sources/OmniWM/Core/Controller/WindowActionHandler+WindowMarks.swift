// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

struct WindowMarkAction: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case set
        case focus
        case summon
        case remove
    }

    let kind: Kind
    let name: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.name.utf8.elementsEqual(rhs.name.utf8)
    }
}

enum WindowMarkFocus {
    case actionTime
    case captured(WindowToken?, workspace: WorkspaceDescriptor.ID?)
}

enum WindowMarkRefusal: String, Error {
    case disabled = "automation is disabled"
    case overviewOpen = "Overview is open"
    case invalidMark = "invalid mark name"
    case duplicateMark = "mark is already assigned to another window"
    case unknownMark = "unknown mark"
    case staleMark = "stale mark"
    case noFocusedWindow = "no focused managed window"
    case focusChanged = "captured focus changed"
    case selfSummon = "cannot summon the anchor window"
    case hiddenWindow = "marked window is hidden"
    case unsupportedLayout = "unsupported layout"
    case windowActionFailed = "window action failed"
}

extension WMController {
    func performWindowMark(
        _ action: borrowing WindowMarkAction, focus: WindowMarkFocus
    ) throws(WindowMarkRefusal) -> ExternalCommandResult {
        switch automationRefusal {
        case .ignoredDisabled: throw .disabled
        case .ignoredOverview: throw .overviewOpen
        default: break
        }
        switch action.kind {
        case .set:
            return try setWindowMark(action.name, focus: focus)
        case .focus:
            let handle = try markedWindow(action.name, requiresEntry: true)
            guard windowActionHandler.navigateToExplicitlySelectedWindow(handle: handle) else {
                throw .windowActionFailed
            }
            return .executed
        case .summon:
            return try summonWindowMark(action.name, focus: focus)
        case .remove:
            switch windowMarkRegistry.remove(action.name) {
            case .removed: return .executed
            case .unknown: throw .unknownMark
            case .invalidName: throw .invalidMark
            }
        }
    }

    private func setWindowMark(
        _ name: String,
        focus: WindowMarkFocus
    ) throws(WindowMarkRefusal) -> ExternalCommandResult {
        let manager = workspaceManager
        let token = manager.nativeManagedFocusToken
        if case let .captured(captured, _) = focus {
            guard let captured else { throw .noFocusedWindow }
            guard token == captured else { throw .focusChanged }
        }
        guard let token, manager.entry(for: token) != nil, manager.handle(for: token) != nil else {
            throw windowMarkRegistry.isValidName(name) ? .noFocusedWindow : .invalidMark
        }
        switch windowMarkRegistry.set(name, for: token) {
        case .inserted: return .executed
        case .unchanged: return .noChange
        case .duplicate: throw .duplicateMark
        case .invalidName: throw .invalidMark
        }
    }

    private func markedWindow(_ name: String, requiresEntry: Bool) throws(WindowMarkRefusal) -> WindowHandle {
        let token: WindowToken
        switch windowMarkRegistry.lookup(name) {
        case let .found(marked): token = marked
        case .unknown: throw .unknownMark
        case .invalidName: throw .invalidMark
        }
        guard !requiresEntry || workspaceManager.entry(for: token) != nil,
              let handle = workspaceManager.handle(for: token)
        else {
            _ = windowMarkRegistry.remove(name)
            throw .staleMark
        }
        return handle
    }

    private func summonWindowMark(
        _ name: String,
        focus: WindowMarkFocus
    ) throws(WindowMarkRefusal) -> ExternalCommandResult {
        let outcome: WindowSummonRightOutcome
        switch focus {
        case .actionTime:
            let handle = try markedWindow(name, requiresEntry: false)
            outcome = windowActionHandler.summonWindowRightOutcome(handle: handle)
        case let .captured(token, workspace):
            guard let token, let workspace else { throw .noFocusedWindow }
            guard matchesAutomationFocus(token, workspaceId: workspace),
                  workspaceManager.selectedManagedToken == token
            else {
                throw .focusChanged
            }
            let handle = try markedWindow(name, requiresEntry: false)
            outcome = windowActionHandler.summonWindowRightOutcome(
                handle: handle, anchorToken: token, anchorWorkspaceId: workspace
            )
        }
        switch outcome {
        case .summoned,
             .movedToWorkspace: return .executed
        case .moveFailed,
             .actionFailed: throw .windowActionFailed
        case .noAnchor: throw .noFocusedWindow
        case .selfSummon: throw .selfSummon
        case .hiddenTarget: throw .hiddenWindow
        case .staleTarget:
            _ = windowMarkRegistry.remove(name)
            throw .staleMark
        case .unsupportedLayout: throw .unsupportedLayout
        }
    }
}
