// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

extension StatusMenuModel {
    var isSecureInputIndicated: Bool {
        controller?.isSecureInputIndicated ?? false
    }

    func showSecureInputExplanation() {
        controller?.showSecureInputExplanation()
    }
}
