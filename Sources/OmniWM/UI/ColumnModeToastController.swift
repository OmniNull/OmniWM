// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

@MainActor
final class ColumnModeToastController {
    struct Source: Equatable {
        let workspaceId: UUID
        let monitorId: Monitor.ID
    }

    enum Message: Equatable {
        case columnMode(isTabbed: Bool)
        case overflowUndone(columnId: NodeId, window: WindowToken?)

        var displayDuration: Duration {
            switch self {
            case .columnMode: .milliseconds(1500)
            case .overflowUndone: .milliseconds(4000)
            }
        }

        var followed: (columnId: NodeId, window: WindowToken?)? {
            switch self {
            case .columnMode: nil
            case let .overflowUndone(columnId, window): (columnId, window)
            }
        }
    }

    static let surfaceId = "column-mode-toast"
    static let topInset: CGFloat = 16
    private static let fadeDuration: TimeInterval = 0.2

    private let ownedWindowRegistry: OwnedWindowRegistry
    private let sleep: @MainActor (Duration) async throws -> Void
    private var surface: (panel: NSPanel, hostingView: NSHostingView<ColumnModeToastView>)?
    private(set) var dismissalTask: Task<Void, Never>?
    private(set) var generation = 0
    private(set) var source: Source?
    private(set) var message: Message?
    private var pillSize: CGSize = .zero

    init(
        ownedWindowRegistry: OwnedWindowRegistry = .shared,
        sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.ownedWindowRegistry = ownedWindowRegistry
        self.sleep = sleep
    }

    isolated deinit {
        destroy()
    }

    func show(
        _ message: Message,
        columnFrame: CGRect,
        visibleFrame: CGRect,
        motion: MotionSnapshot,
        source: Source
    ) {
        if let visiblePanel = surface?.panel, visiblePanel.isVisible, !visiblePanel.isOnActiveSpace {
            destroy()
        }
        let (panel, hostingView) = surface ?? makeSurface()

        dismissalTask?.cancel()
        generation += 1
        self.source = source
        self.message = message
        hostingView.rootView = ColumnModeToastView(message: message)
        pillSize = hostingView.fittingSize
        panel.setFrame(
            Self.pillFrame(size: pillSize, columnFrame: columnFrame, visibleFrame: visibleFrame),
            display: true
        )
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        panel.orderFrontRegardless()

        let shownGeneration = generation
        let sleep = sleep
        dismissalTask = Task { @MainActor [weak self] in
            do {
                try await sleep(message.displayDuration)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.fadeOut(generation: shownGeneration, animated: motion.animationsEnabled)
        }
    }

    func move(columnFrame: CGRect, visibleFrame: CGRect) {
        guard let panel = surface?.panel, panel.isVisible else { return }
        let origin = Self.pillFrame(size: pillSize, columnFrame: columnFrame, visibleFrame: visibleFrame).origin
        if panel.frame.origin != origin {
            panel.setFrameOrigin(origin)
        }
    }

    func hide() {
        dismissalTask?.cancel()
        dismissalTask = nil
        source = nil
        message = nil
        surface?.panel.orderOut(nil)
    }

    func destroy() {
        hide()
        guard let surface else { return }
        ownedWindowRegistry.unregister(surfaceId: Self.surfaceId)
        surface.panel.close()
        self.surface = nil
    }

    static func pillFrame(size: CGSize, columnFrame: CGRect, visibleFrame: CGRect) -> CGRect {
        let x = columnFrame.midX - size.width / 2
        let y = columnFrame.maxY - topInset - size.height
        let clampedX = min(max(x, visibleFrame.minX), visibleFrame.maxX - size.width)
        let clampedY = min(max(y, visibleFrame.minY), visibleFrame.maxY - size.height)
        return CGRect(origin: CGPoint(x: clampedX, y: clampedY), size: size)
    }

    private func fadeOut(generation shownGeneration: Int, animated: Bool) {
        guard let panel = surface?.panel, animated else {
            hide()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.finishFade(generation: shownGeneration)
            }
        }
    }

    func finishFade(generation shownGeneration: Int) {
        guard generation == shownGeneration else { return }
        hide()
    }

    private func makeSurface() -> (panel: NSPanel, hostingView: NSHostingView<ColumnModeToastView>) {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let hostingView = NSHostingView(rootView: ColumnModeToastView(message: .columnMode(isTabbed: false)))
        panel.contentView = hostingView

        ownedWindowRegistry.register(
            panel,
            surfaceId: Self.surfaceId,
            policy: SurfacePolicy(
                kind: .columnModeToast,
                hitTestPolicy: .passthrough,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: false
            )
        )
        surface = (panel, hostingView)
        return (panel, hostingView)
    }
}

struct ColumnModeToastView: View {
    let message: ColumnModeToastController.Message

    private var text: LocalizedStringKey {
        switch message {
        case let .columnMode(isTabbed): isTabbed ? "Tabbed mode on" : "Tabbed mode off"
        case .overflowUndone: "Not enough room for these windows, so the change was undone."
        }
    }

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14)
            .frame(height: 30)
            .omniGlassEffect(in: Capsule())
            .fixedSize()
    }
}
