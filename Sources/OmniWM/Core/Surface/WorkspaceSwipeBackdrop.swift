// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
final class WorkspaceSwipeBackdrop {
    private let wallpaperCache: OverviewWallpaperCache

    init(wallpaperCache: OverviewWallpaperCache = OverviewWallpaperCache()) {
        self.wallpaperCache = wallpaperCache
    }

    func image(for monitor: Monitor) -> CGImage? {
        let key = cacheKey(for: monitor)
        return wallpaperCache.image(for: monitor.displayId, maxPixelSize: key.maxPixelSize, frame: key.frame)
    }

    func hasImage(for monitor: Monitor) -> Bool {
        let key = cacheKey(for: monitor)
        return wallpaperCache.hasCapturedImage(for: monitor.displayId, maxPixelSize: key.maxPixelSize, frame: key.frame)
    }

    private func cacheKey(for monitor: Monitor) -> (maxPixelSize: Int, frame: CGRect) {
        (
            OverviewWallpaperCache.bucketedPixelSize(max(monitor.frame.width, monitor.frame.height)),
            ScreenCoordinateSpace.toWindowServer(rect: monitor.frame)
        )
    }

    func clear() {
        wallpaperCache.clear()
    }
}
