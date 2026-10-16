// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension ShellWidgetHost {
    func deliverDesktop(_ submissions: [ShellDesktopSubmission], package: ShellWidgetPackage) {
        for submission in submissions {
            let bridge = ShellDesktopResourceBridge(admit: { id, values in
                try await package.admitResources(values, owner: id.owner, component: submission.component)
            }, retireIDs: { owner, ids in
                await package.retireResourceIDs(ids, owner: owner)
            })
            let source = submission.origin.flatMap { desktopSource(for: $0) }
            let resolveAnchor: (@MainActor () async throws -> ShellDesktopAnchor)?
            if let locator = submission.request.anchor, let origin = submission.origin {
                resolveAnchor = { [weak self, weak package] in
                    guard let self, let package else { throw ShellResourceFailure("source_surface_unavailable") }
                    let resolution = try await package.resolveDesktopAnchor(
                        locator,
                        owner: submission.request.id.owner,
                        origin: origin
                    )
                    guard let anchor = desktopAnchor(for: origin, resolution: resolution) else {
                        throw ShellResourceFailure("anchor_unavailable")
                    }
                    return anchor
                }
            } else { resolveAnchor = nil }
            desktopServices.perform(
                submission.request,
                ledger: package.services,
                bridge: bridge,
                source: source,
                resolveAnchor: resolveAnchor,
                registered: true
            )
        }
    }
}
