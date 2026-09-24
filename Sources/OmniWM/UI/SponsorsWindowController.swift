// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

@MainActor
final class SponsorsWindowController {
    private let presenter: HostedWindowPresenter
    private let motionPolicy: MotionPolicy

    init(
        motionPolicy: MotionPolicy,
        ownedWindowRegistry: OwnedWindowRegistry = .shared
    ) {
        presenter = HostedWindowPresenter(ownedWindowRegistry: ownedWindowRegistry)
        self.motionPolicy = motionPolicy
    }

    func show() {
        presenter.present(
            title: String(localized: "Omni Sponsors"),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            contentSize: NSSize(width: 1280, height: 1040),
            minSize: NSSize(width: 760, height: 640),
            configure: { window in
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.isOpaque = false
                window.backgroundColor = .clear
            },
            content: {
                SponsorsView(
                    motionPolicy: motionPolicy,
                    onClose: { [weak presenter] in
                        presenter?.close()
                    }
                )
            }
        )
    }
}
