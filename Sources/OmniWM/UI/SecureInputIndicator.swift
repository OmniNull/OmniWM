// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

private let explanationWidth: CGFloat = 380
private let screenInset: CGFloat = 20

@MainActor
final class SecureInputIndicatorController {
    static let surfaceId = "secure-input-indicator"
    static let explanationDelay: Duration = .seconds(10)

    var openHotkeysSettings: () -> Void = {}
    private(set) var isIndicated = false
    private(set) var explanationTask: Task<Void, Never>?
    private var generation = 0
    private var panel: NSPanel?
    private let ownedWindowRegistry: OwnedWindowRegistry
    private let sleep: @MainActor (Duration) async throws -> Void

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

    var isExplanationVisible: Bool {
        panel?.isVisible == true
    }

    @discardableResult
    func setIndicated(_ indicated: Bool) -> Bool {
        guard indicated != isIndicated else { return false }
        isIndicated = indicated
        generation += 1
        cancelScheduledExplanation()
        if indicated {
            scheduleExplanation()
        } else {
            hideExplanation()
        }
        return true
    }

    func showExplanation() {
        guard isIndicated else { return }
        cancelScheduledExplanation()
        let panel = panel ?? makePanel()
        if let screen = NSScreen.screen(containing: NSEvent.mouseLocation) ?? NSScreen.main,
           let contentView = panel.contentView
        {
            panel.setFrame(
                Self.panelFrame(size: contentView.fittingSize, visibleFrame: screen.visibleFrame),
                display: true
            )
        }
        panel.orderFrontRegardless()
    }

    func hideExplanation() {
        panel?.orderOut(nil)
    }

    func destroy() {
        cancelScheduledExplanation()
        guard let panel else { return }
        panel.orderOut(nil)
        ownedWindowRegistry.unregister(surfaceId: Self.surfaceId)
        panel.close()
        self.panel = nil
    }

    static func panelFrame(size: CGSize, visibleFrame: CGRect) -> CGRect {
        CGRect(
            x: visibleFrame.maxX - size.width - screenInset,
            y: visibleFrame.minY + screenInset,
            width: size.width,
            height: size.height
        )
    }

    private func scheduleExplanation() {
        let scheduledGeneration = generation
        let sleep = sleep
        explanationTask = Task { @MainActor [weak self] in
            do {
                try await sleep(Self.explanationDelay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, generation == scheduledGeneration else { return }
            explanationTask = nil
            showExplanation()
        }
    }

    private func cancelScheduledExplanation() {
        explanationTask?.cancel()
        explanationTask = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NonactivatingPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isOpaque = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.contentView = NSHostingView(
            rootView: SecureInputExplanationView(
                onOpenHotkeysSettings: { [weak self] in
                    self?.hideExplanation()
                    self?.openHotkeysSettings()
                },
                onClose: { [weak self] in
                    self?.hideExplanation()
                }
            )
        )
        ownedWindowRegistry.register(
            panel,
            surfaceId: Self.surfaceId,
            policy: SurfacePolicy(
                kind: .secureInputIndicator,
                hitTestPolicy: .interactive,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: false
            )
        )
        self.panel = panel
        return panel
    }
}

struct SecureInputExplanationView: View {
    let onOpenHotkeysSettings: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(Color(nsColor: .systemRed))
                Text("Secure Input is on")
                    .font(.headline)
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close")
                .accessibilityLabel("Close")
            }
            Group {
                Text(
                    "Until it turns off, shortcuts that use only Option or Option + Shift with a letter, number, or symbol key are paused, along with Hyper and left/right-specific shortcuts. Shortcuts with Control or Command keep working."
                )
                Text(
                    "Apps turn it on to protect what you type: Terminal or iTerm with Secure Keyboard Entry, password managers, and browser password fields. If it stays on, quit the app that turned it on."
                )
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Button("Open Hotkeys Settings", action: onOpenHotkeysSettings)
        }
        .padding(16)
        .frame(width: explanationWidth, alignment: .leading)
        .omniGlassEffect(in: RoundedRectangle(cornerRadius: 12))
    }
}
