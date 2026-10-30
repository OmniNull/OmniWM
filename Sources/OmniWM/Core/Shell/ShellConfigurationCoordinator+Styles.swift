// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension ShellConfigurationCoordinator {
    var profiles: [String] {
        styles.map(\.name)
    }

    func style(_ profile: String) -> ShellStyle {
        styles.first { $0.name == profile } ?? ShellStyle(name: profile)
    }
}
