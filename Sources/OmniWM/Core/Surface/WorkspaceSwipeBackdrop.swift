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
        wallpaperCache.image(
            for: monitor.displayId,
            maxPixelSize: OverviewWallpaperCache.bucketedPixelSize(max(monitor.frame.width, monitor.frame.height)),
            frame: ScreenCoordinateSpace.toWindowServer(rect: monitor.frame)
        )
    }

    func clear() {
        wallpaperCache.clear()
    }
}
