// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

final class ShellResourceSecurityScope: Sendable {
    let url: URL
    private let stop: @Sendable (URL) -> Void

    private init(url: URL, stop: @escaping @Sendable (URL) -> Void) {
        self.url = url
        self.stop = stop
    }

    static func begin(
        _ url: URL,
        start: @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        stop: @escaping @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    ) -> ShellResourceSecurityScope? {
        guard start(url) else { return nil }
        return ShellResourceSecurityScope(url: url, stop: stop)
    }

    deinit { stop(url) }
}
