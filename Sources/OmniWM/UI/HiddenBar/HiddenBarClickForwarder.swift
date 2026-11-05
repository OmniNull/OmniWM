// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices

@MainActor
final class HiddenBarClickForwarder {
    private static let warpSettleDelay: Duration = .milliseconds(10)
    private static let cursorRestoreDelay: Duration = .milliseconds(50)
    private static let menuOpenCheckDelay: Duration = .milliseconds(1500)

    var onCursorWarp: ((CGPoint) -> Void)?

    private let itemService: MenuBarItemService
    private var diagnosticTask: Task<Void, Never>?
    private var diagnosticGeneration = 0

    init(itemService: MenuBarItemService) {
        self.itemService = itemService
    }

    func forward(to target: ResolvedMenuBarItem) async {
        diagnosticTask?.cancel()
        diagnosticTask = nil
        diagnosticGeneration += 1
        await run(target)
    }

    func cancel() {
        diagnosticGeneration += 1
        diagnosticTask?.cancel()
        diagnosticTask = nil
    }

    private func run(_ target: ResolvedMenuBarItem) async {
        let key = target.key
        let covered = Self.isCoveredByOwnWindow(CGPoint(x: target.bounds.midX, y: target.bounds.midY))
        let candidates: [MenuBarItemActivationCandidate] = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.bundleIdentifier == key.bundleID,
                  app.processIdentifier == target.pid
            else { return nil }
            return Self.activationCandidate(
                pid: app.processIdentifier,
                covered: covered,
                electron: Self.isElectronApp(app)
            )
        }
        guard !candidates.isEmpty else { return }

        let activation = await itemService.activate(
            candidates: candidates,
            target: target
        )
        guard !Task.isCancelled else { return }

        switch activation {
        case .axPressed:
            return
        case let .clickFrame(frame):
            await postClick(at: frame)
            guard !Task.isCancelled else { return }
            scheduleMenuOpenDiagnostic(bundleID: key.bundleID)
        case .unavailable:
            FallbackFiringRecorder.shared.note(.ax, "hiddenBarLocateTimeout")
        }
    }

    nonisolated static func activationCandidate(
        pid: pid_t,
        covered: Bool,
        electron: Bool
    ) -> MenuBarItemActivationCandidate {
        MenuBarItemActivationCandidate(pid: pid, useAXPress: covered || electron, allowsClick: !covered)
    }

    nonisolated static func isCoveredByOwnWindow(_ point: CGPoint) -> Bool {
        isCoveredByOwnWindow(
            point,
            windows: CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] ?? []
        )
    }

    nonisolated static func isCoveredByOwnWindow(_ point: CGPoint, windows: [[String: Any]]) -> Bool {
        let own = ProcessInfo.processInfo.processIdentifier
        return windows.contains { window in
            guard window[kCGWindowOwnerPID as String] as? pid_t == own,
                  let info = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: info)
            else { return false }
            return bounds.contains(point)
        }
    }

    private static func isElectronApp(_ app: NSRunningApplication) -> Bool {
        guard let bundleURL = app.bundleURL else { return false }
        let framework = bundleURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        return FileManager.default.fileExists(atPath: framework.path)
    }

    private func postClick(at frame: CGRect) async {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            FallbackFiringRecorder.shared.note(.input, "hiddenBarClickSourceFailed")
            return
        }
        let clickPoint = CGPoint(x: frame.midX, y: frame.midY)
        guard let mouseDown = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDown,
            mouseCursorPosition: clickPoint,
            mouseButton: .left
        ), let mouseUp = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseUp,
            mouseCursorPosition: clickPoint,
            mouseButton: .left
        ) else {
            FallbackFiringRecorder.shared.note(.input, "hiddenBarClickEventFailed")
            return
        }

        for event in [mouseDown, mouseUp] {
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }

        let restorePoint = CGEvent(source: nil)?.location
        CGWarpMouseCursorPosition(clickPoint)
        onCursorWarp?(ScreenCoordinateSpace.toAppKit(point: clickPoint))
        try? await Task.sleep(for: Self.warpSettleDelay)
        if !Task.isCancelled {
            mouseDown.post(tap: .cghidEventTap)
            mouseUp.post(tap: .cghidEventTap)
            try? await Task.sleep(for: Self.cursorRestoreDelay)
        }
        if let restorePoint {
            CGWarpMouseCursorPosition(restorePoint)
            onCursorWarp?(ScreenCoordinateSpace.toAppKit(point: restorePoint))
        }
    }

    private func scheduleMenuOpenDiagnostic(bundleID: String) {
        diagnosticTask?.cancel()
        diagnosticGeneration += 1
        let generation = diagnosticGeneration
        diagnosticTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.menuOpenCheckDelay)
            guard let self, !Task.isCancelled, generation == diagnosticGeneration else { return }
            let ownerPIDs = Set(
                NSWorkspace.shared.runningApplications.compactMap { app in
                    app.bundleIdentifier == bundleID ? app.processIdentifier : nil
                }
            )
            let menuOpen = await itemService.isMenuOpen(ownerPIDs: ownerPIDs)
            guard !Task.isCancelled, generation == diagnosticGeneration else { return }
            if menuOpen == false {
                FallbackFiringRecorder.shared.note(.input, "hiddenBarClickNoMenu")
            }
            if generation == diagnosticGeneration {
                diagnosticTask = nil
            }
        }
    }
}
