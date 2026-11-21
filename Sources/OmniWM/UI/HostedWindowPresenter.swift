// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

@MainActor
final class HostedWindowPresenter {
    private(set) var window: NSWindow?
    private let ownedWindowRegistry: OwnedWindowRegistry
    private let orderFront: @MainActor (NSWindow) -> Void
    private var closeObserver: (any NSObjectProtocol)?

    init(
        ownedWindowRegistry: OwnedWindowRegistry = .shared,
        orderFront: @escaping @MainActor (NSWindow) -> Void = { window in
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    ) {
        self.ownedWindowRegistry = ownedWindowRegistry
        self.orderFront = orderFront
    }

    func present(
        title: String,
        styleMask: NSWindow.StyleMask,
        contentSize: NSSize,
        minSize: NSSize,
        center: (NSWindow) -> Void = { $0.center() },
        configure: (NSWindow) -> Void = { _ in },
        onWillClose: @escaping @MainActor () -> Void = {},
        onPresented: (NSWindow) -> Void = { _ in },
        content: () -> some View
    ) {
        if let window {
            orderFront(window)
            return
        }

        let window = NSWindow(contentViewController: NSHostingController(rootView: content()))
        window.title = title
        window.styleMask = styleMask
        window.setContentSize(contentSize)
        window.minSize = minSize
        window.isReleasedWhenClosed = false
        configure(window)
        center(window)
        ownedWindowRegistry.register(window)
        orderFront(window)

        closeObserver = NotificationCenter.default
            .addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let closeObserver = self.closeObserver {
                        NotificationCenter.default.removeObserver(closeObserver)
                    }
                    self.closeObserver = nil
                    self.ownedWindowRegistry.windowWillClose(window)
                    self.window = nil
                    onWillClose()
                }
            }
        self.window = window
        onPresented(window)
    }

    func close() {
        window?.close()
    }
}
