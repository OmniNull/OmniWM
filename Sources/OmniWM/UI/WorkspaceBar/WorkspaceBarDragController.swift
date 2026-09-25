// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Observation

@MainActor @Observable
final class WorkspaceBarDragPresentation {
    var sourceTokens: Set<WindowToken> = []
    var highlights: [WorkspaceBarDropHighlight] = []

    func clear() {
        if !sourceTokens.isEmpty { sourceTokens = [] }
        if !highlights.isEmpty { highlights = [] }
    }
}

@MainActor
final class WorkspaceBarDragController {
    private struct Session {
        let source: WorkspaceBarDragSource
        var geometry: WorkspaceBarDropGeometry
        var geometryVersion: UInt64
        let ghost: WorkspaceBarDragGhost?
    }

    let presentation = WorkspaceBarDragPresentation()
    var geometryProvider: () -> WorkspaceBarDropGeometry = { WorkspaceBarDropGeometry(workspaces: []) }
    var geometryVersion: () -> UInt64 = { 0 }
    var commit: (WorkspaceBarDropAction, WorkspaceBarDragSource) -> Bool = { _, _ in false }
    var makeGhost: (NSImage?) -> WorkspaceBarDragGhost? = { _ in nil }
    var sourceIsValid: (WorkspaceBarDragSource) -> Bool = { _ in true }
    private let escapeMonitor = PanelDismissalMonitor()
    private var session: Session?
    private var clearsPresentationOnNextUpdate = false

    var isDragging: Bool {
        session != nil
    }

    func begin(source: WorkspaceBarDragSource, icon: NSImage?, at point: CGPoint) {
        cancel()
        clearsPresentationOnNextUpdate = false
        let version = geometryVersion()
        let geometry = geometryProvider()
        let resolution = WorkspaceBarDropResolver.resolve(source: source, at: point, in: geometry)
        let ghost = makeGhost(icon)
        session = Session(source: source, geometry: geometry, geometryVersion: version, ghost: ghost)
        presentation.sourceTokens = Set(source.tokens)
        apply(resolution, at: point)
        if let ghost {
            escapeMonitor.start(
                panels: [ghost],
                isExemptWindow: { _ in true },
                onEscape: { [weak self] in self?.cancel() },
                onDismiss: { [weak self] in self?.cancel() }
            )
        }
    }

    func update(at point: CGPoint) {
        guard let session = refreshedSession() else { return }
        apply(WorkspaceBarDropResolver.resolve(source: session.source, at: point, in: session.geometry), at: point)
    }

    @discardableResult
    func end(at point: CGPoint) -> Bool {
        guard let session = refreshedSession() else { return false }
        let resolution = WorkspaceBarDropResolver.resolve(source: session.source, at: point, in: session.geometry)
        let committed = switch resolution.action {
        case .cancel,
             .noOp: false
        default: commit(resolution.action, session.source)
        }
        finishSession(keepingPresentation: committed)
        return committed
    }

    func cancel() {
        guard session != nil else { return }
        finishSession()
    }

    func barsDidUpdate() {
        if clearsPresentationOnNextUpdate {
            clearsPresentationOnNextUpdate = false
            presentation.clear()
        }
        guard var session else { return }
        guard sourceIsValid(session.source) else {
            cancel()
            return
        }
        session.geometryVersion = geometryVersion()
        session.geometry = geometryProvider()
        self.session = session
    }

    private func refreshedSession() -> Session? {
        guard var session else { return nil }
        let version = geometryVersion()
        guard version != session.geometryVersion else { return session }
        session.geometryVersion = version
        session.geometry = geometryProvider()
        self.session = session
        return session
    }

    private func apply(_ resolution: WorkspaceBarDropResolution, at point: CGPoint) {
        if presentation.highlights != resolution.highlights {
            presentation.highlights = resolution.highlights
        }
        session?.ghost?.update(label: resolution.label, isValid: resolution.action != .cancel)
        session?.ghost?.moveTo(cursorLocation: point)
    }

    private func finishSession(keepingPresentation: Bool = false) {
        escapeMonitor.stop()
        session?.ghost?.destroy()
        session = nil
        if keepingPresentation {
            clearsPresentationOnNextUpdate = true
        } else {
            presentation.clear()
        }
    }
}
