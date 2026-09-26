// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

struct WorkspaceBarHoverTarget: Equatable {
    struct Window: Equatable {
        let handle: WindowHandle
        let title: String
        let appName: String
        let icon: NSImage?
    }

    let key: WorkspaceBarHitTarget
    let windows: [Window]
    let attachment: PopupAttachment
    let visibleFrame: CGRect
    let level: NSWindow.Level
}

@MainActor
final class WorkspaceBarHoverPreviewController {
    typealias Scheduler = @MainActor (Duration, @escaping @MainActor () -> Void) -> () -> Void

    private enum Phase {
        case idle
        case pending(WorkspaceBarHoverTarget, cancel: () -> Void)
        case visible(WorkspaceBarHoverTarget)
        case closing(WorkspaceBarHoverTarget, cancel: () -> Void)
    }

    static let openDelay: Duration = .milliseconds(500)
    static let closeGrace: Duration = .milliseconds(150)
    static let maximumTiles = 4

    private let capture: OverviewThumbnailCapture
    private let hasCaptureAccess: () -> Bool
    private let scheduleAfter: Scheduler
    private let makePanel: () -> WorkspaceBarPreviewPanel?
    private var panel: WorkspaceBarPreviewPanel?
    private var phase = Phase.idle
    private var suppressedKey: WorkspaceBarHitTarget?
    private var isPointerInPanel = false
    var onSelect: (WindowHandle) -> Void = { _ in }

    init(
        capture: OverviewThumbnailCapture,
        hasCaptureAccess: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
        scheduleAfter: @escaping Scheduler = WorkspaceBarHoverPreviewController.scheduleWithTask,
        makePanel: @escaping () -> WorkspaceBarPreviewPanel? = { nil }
    ) {
        self.capture = capture
        self.hasCaptureAccess = hasCaptureAccess
        self.scheduleAfter = scheduleAfter
        self.makePanel = makePanel
        capture.onPreview = { [weak self] handle, frame in
            self?.panel?.updatePreview(frame, for: handle)
        }
    }

    var visibleTarget: WorkspaceBarHoverTarget? {
        switch phase {
        case let .visible(target),
             let .closing(target, _): target
        case .idle,
             .pending: nil
        }
    }

    func hoverBegan(_ target: WorkspaceBarHoverTarget) {
        guard suppressedKey != target.key, !target.windows.isEmpty else { return }
        switch phase {
        case .visible,
             .closing:
            show(target)
        case let .pending(pending, cancel):
            guard pending.key != target.key else { return }
            cancel()
            schedule(target)
        case .idle:
            schedule(target)
        }
    }

    func hoverEnded(_ key: WorkspaceBarHitTarget) {
        if suppressedKey == key {
            suppressedKey = nil
        }
        switch phase {
        case let .pending(target, cancel) where target.key == key:
            cancel()
            phase = .idle
        case let .visible(target) where target.key == key:
            beginClosing(target)
        default:
            break
        }
    }

    func pointerInPanelChanged(_ inside: Bool) {
        isPointerInPanel = inside
        switch phase {
        case let .closing(target, cancel) where inside:
            cancel()
            phase = .visible(target)
        case let .visible(target) where !inside:
            beginClosing(target)
        default:
            break
        }
    }

    func dismiss(suppressing key: WorkspaceBarHitTarget? = nil) {
        suppressedKey = key ?? suppressedKey
        switch phase {
        case let .pending(_, cancel),
             let .closing(_, cancel):
            cancel()
        case .idle,
             .visible:
            break
        }
        hide()
    }

    func targetsDidChange(resolve: (WorkspaceBarHitTarget) -> WorkspaceBarHoverTarget?) {
        switch phase {
        case let .pending(target, cancel):
            guard let current = resolve(target.key) else {
                cancel()
                phase = .idle
                return
            }
            phase = .pending(current, cancel: cancel)
        case let .visible(target):
            guard let current = resolve(target.key), current.attachment == target.attachment else {
                dismiss()
                return
            }
            if current != target {
                show(current)
            }
        case let .closing(target, _):
            if resolve(target.key) != target {
                dismiss()
            }
        case .idle:
            break
        }
    }

    private func schedule(_ target: WorkspaceBarHoverTarget) {
        let cancel = scheduleAfter(Self.openDelay) { [weak self] in
            guard let self, case let .pending(pending, _) = phase, pending.key == target.key else { return }
            show(pending)
        }
        phase = .pending(target, cancel: cancel)
    }

    private func beginClosing(_ target: WorkspaceBarHoverTarget) {
        guard !isPointerInPanel else { return }
        let cancel = scheduleAfter(Self.closeGrace) { [weak self] in
            guard let self, case let .closing(closing, _) = phase, closing.key == target.key else { return }
            hide()
        }
        phase = .closing(target, cancel: cancel)
    }

    private func show(_ target: WorkspaceBarHoverTarget) {
        if case let .closing(_, cancel) = phase {
            cancel()
        }
        let windows = Array(target.windows.prefix(Self.maximumTiles))
        let showsThumbnails = hasCaptureAccess()
        let panel = panel ?? makePanel()
        self.panel = panel
        panel?.onSelect = { [weak self] handle in
            self?.dismiss()
            self?.onSelect(handle)
        }
        panel?.onPointerInside = { [weak self] inside in
            self?.pointerInPanelChanged(inside)
        }
        panel?.show(
            target,
            windows: windows,
            overflowCount: target.windows.count - windows.count,
            showsThumbnails: showsThumbnails,
            cachedPreview: { [capture] in capture.preview(for: $0) }
        )
        phase = .visible(target)
        guard showsThumbnails else {
            capture.clear()
            return
        }
        let tileSize = WorkspaceBarPreviewPanel.tileSize(forWindowCount: windows.count)
        let scale = NSScreen.screen(containing: target.attachment.anchor)?
            .backingScaleFactor ?? 2
        capture.reconcile(
            represented: Set(windows.map(\.handle)),
            visible: windows.map {
                OverviewPreviewRequest(
                    handle: $0.handle,
                    pixelWidth: Int(tileSize.width * scale),
                    pixelHeight: Int(tileSize.height * scale)
                )
            }
        )
    }

    private func hide() {
        phase = .idle
        isPointerInPanel = false
        capture.clear()
        panel?.hide()
    }

    static func scheduleWithTask(_ delay: Duration, _ action: @escaping @MainActor () -> Void) -> () -> Void {
        let task = Task { @MainActor in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            action()
        }
        return { task.cancel() }
    }
}
