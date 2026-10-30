// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ScreenCaptureKit

@MainActor
enum WorkspaceSwipeDisplaySnapshot {
    static func capture(monitor: Monitor, frame: CGRect, registry: OwnedWindowRegistry) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == monitor.displayId }) else {
                return nil
            }
            let iconLayer = Int(CGWindowLevelForKey(.desktopIconWindow))
            let included = content.windows.filter {
                $0.windowLayer != iconLayer && registry.isCaptureEligible(windowNumber: Int($0.windowID))
            }
            let rect = ScreenCoordinateSpace.toWindowServer(rect: frame)
            let config = SCStreamConfiguration()
            config.sourceRect = rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            config.width = Int(ceil(frame.width))
            config.height = Int(ceil(frame.height))
            config.showsCursor = false
            config.capturesAudio = false
            return try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, including: included),
                configuration: config
            )
        } catch {
            ScreenCapturePermissionMonitor.shared.noteCaptureFailure(error)
            FallbackFiringRecorder.shared.note(.capture, "workspaceSwipeSnapshotException")
            return nil
        }
    }
}
