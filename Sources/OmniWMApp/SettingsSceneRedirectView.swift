// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Observation
import OmniWM
import SwiftUI

struct SettingsSceneRedirectView: View {
    @Bindable var bootstrap: AppBootstrapState

    @State private var window: NSWindow?
    @State private var didRedirect = false

    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text(didRedirect ? String(localized: "Opening OmniWM Settings…") : String(localized: "Starting OmniWM…"))
                .foregroundColor(.secondary)
        }
        .frame(width: 1, height: 1)
        .background(
            WindowCaptureView { newWindow in
                updateWindow(newWindow)
            }
        )
        .onAppear {
            redirectIfPossible()
        }
        .onChange(of: bootstrap.isReady) { _, _ in
            redirectIfPossible()
        }
        .onDisappear {
            if let window {
                bootstrap.unregisterRedirectWindow(window)
            }
        }
    }

    private func updateWindow(_ newWindow: NSWindow?) {
        if let window {
            if let newWindow {
                if window !== newWindow {
                    bootstrap.unregisterRedirectWindow(window)
                }
            } else {
                bootstrap.unregisterRedirectWindow(window)
            }
        }
        window = newWindow
        if let newWindow {
            bootstrap.registerRedirectWindow(newWindow)
        }
        redirectIfPossible()
    }

    private func redirectIfPossible() {
        guard !didRedirect,
              bootstrap.isReady
        else { return }

        didRedirect = true
        bootstrap.showSettingsAndCloseRedirectWindow(window)
    }
}

private struct WindowCaptureView: NSViewRepresentable {
    let onChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowCaptureNSView {
        WindowCaptureNSView(onChange: onChange)
    }

    func updateNSView(_ nsView: WindowCaptureNSView, context: Context) {
        nsView.onChange = onChange
    }
}

private final class WindowCaptureNSView: NSView {
    var onChange: (NSWindow?) -> Void

    init(onChange: @escaping (NSWindow?) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onChange(window)
    }
}
