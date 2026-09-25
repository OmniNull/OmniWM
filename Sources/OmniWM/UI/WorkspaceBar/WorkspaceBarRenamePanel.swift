// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

@MainActor
final class WorkspaceBarRenamePanel {
    private static let surfaceId = "workspace-bar-rename"
    private static let contentSize = CGSize(width: 220, height: 44)

    private let ownedWindowRegistry: OwnedWindowRegistry
    private let focusPolicyEngine: FocusPolicyEngine
    private let dismissalMonitor = PanelDismissalMonitor()
    private var panel: NonactivatingPanel?
    private var hostingView: NSHostingView<AnyView>?
    var isExemptWindow: (NSWindow) -> Bool = { _ in false }

    private(set) var isVisible = false

    init(ownedWindowRegistry: OwnedWindowRegistry, focusPolicyEngine: FocusPolicyEngine) {
        self.ownedWindowRegistry = ownedWindowRegistry
        self.focusPolicyEngine = focusPolicyEngine
    }

    func show(
        currentName: String,
        placeholder: String,
        anchor: CGRect,
        visibleFrame: CGRect,
        onCommit: @escaping (String) -> Void
    ) {
        dismiss()
        let panel = panel ?? makePanel()
        self.panel = panel
        hostingView?.rootView = AnyView(
            WorkspaceBarRenameView(
                text: currentName,
                placeholder: placeholder,
                onSubmit: { [weak self] name in
                    self?.dismiss()
                    onCommit(name)
                },
                onCancel: { [weak self] in self?.dismiss() }
            )
        )
        panel.setFrame(
            NonactivatingPanel.frame(
                anchor: CGPoint(x: anchor.midX, y: anchor.minY),
                size: Self.contentSize,
                screenVisibleFrame: visibleFrame
            ),
            display: true
        )
        isVisible = true
        ownedWindowRegistry.register(
            panel,
            surfaceId: Self.surfaceId,
            policy: SurfacePolicy(
                kind: .utility,
                hitTestPolicy: .interactive,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: true
            )
        )
        focusPolicyEngine.beginLease(owner: .workspaceBarRename, reason: "workspace_bar_rename", duration: nil)
        panel.makeKeyAndOrderFront(nil)
        dismissalMonitor.start(
            panels: [panel],
            isExemptWindow: { [weak self] in self?.isExemptWindow($0) == true },
            onDismiss: { [weak self] in self?.dismiss() }
        )
    }

    func dismiss() {
        guard isVisible else { return }
        isVisible = false
        dismissalMonitor.stop()
        panel?.orderOut(nil)
        ownedWindowRegistry.unregister(surfaceId: Self.surfaceId)
        focusPolicyEngine.endLease(owner: .workspaceBarRename)
        hostingView?.rootView = AnyView(EmptyView())
    }

    private func makePanel() -> NonactivatingPanel {
        let panel = NonactivatingPanel(
            contentRect: CGRect(origin: .zero, size: Self.contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.title = String(localized: "Rename Workspace")
        let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        self.hostingView = hostingView
        return panel
    }
}

@MainActor
private struct WorkspaceBarRenameView: View {
    @State var text: String
    let placeholder: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .onSubmit { onSubmit(text) }
            .onExitCommand(perform: onCancel)
            .accessibilityLabel("Workspace name")
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onAppear { isFocused = true }
    }
}
