// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

extension OverviewController {
    func toggle() {
        switch state {
        case .closed:
            open()
        case .opening:
            if isInteractiveTransitionActive, transitionProgress < 0.5 {
                commitOpen()
            } else {
                input.dismissToSelection(animated: true)
            }
        case .open:
            input.dismissToSelection(animated: true)
        case .closing:
            reverseClosingTransition()
        }
    }
}
