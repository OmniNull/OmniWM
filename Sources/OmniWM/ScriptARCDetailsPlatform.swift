// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import OmniWMScriptHost
import ScriptARCCounters

@MainActor
package func runScriptARCDetailsPlatform(directory: URL) async throws {
    _ = NSApplication.shared
    script_arc_install()
    let count = ScriptARCFixture.workspaceRows
    let fixture = try ScriptARCFixture(
        directory: directory.appendingPathComponent("details-platform"),
        snapshotRows: count
    )
    defer { fixture.script.stop() }
    let controller = fixture.controller
    let manager = controller.workspaceManager
    let monitor = notchedAuditMonitor(manager.monitors[0])
    manager.applyMonitorConfigurationChange([monitor])
    precondition(!controller.settings.workspaceBar.enabled && manager.monitors == [monitor])
    fixture.populateSnapshotLayout(.niri)
    fixture.seedSnapshotFrames(count)
    let queue = try await fixture.acceptTitleScript("omniwm.command('Inspect', function() end)")
    await queue.waitUntilParked()
    precondition(controller.windowMarkRegistry.set("platform-audit-title", for: fixture.snapshotCachedTitleToken)
        == .inserted)
    controller.appInfoCache.evict(pid: fixture.token.pid)
    for offset in 0 ..< count {
        AXWindowService.invalidateCachedTitle(windowId: UInt32(fixture.token.windowId + offset))
    }
    controller.layoutRefreshController.layoutState.backingScaleByDisplay = nil
    controller.cachedMonitorLayout = nil
    controller.cachedInnerGap = nil

    calibrateDetailPlatformReads()
    let reads: ConfigScriptReads = [
        .workspaceWindows, .workspaceWindowFrames, .workspaceWindowColumns, .workspaceWindowDetails,
        .windows, .windowFrames, .windowColumns, .windowDetails, .workspaces, .workspaceDetails,
        .monitors, .monitorFrames, .monitorDetails, .marks
    ]
    let expectedFlags = UInt8(OMNI_CONFIG_SECTION_DETAILS | OMNI_CONFIG_SECTION_FRAMES | OMNI_CONFIG_SECTION_COLUMNS)
    for warm in [false, true] {
        if warm { warmWindowDetailTextCaches(fixture, count: count) }
        script_arc_begin()
        let capture = queue.capture(reads: reads, controller: controller)
        script_arc_end()
        precondition(capture.target.token == fixture.token)
        let header = capture.snapshot!.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
        precondition(UInt8(truncatingIfNeeded: header >> 8) == expectedFlags)
        precondition(UInt16(truncatingIfNeeded: header >> 16) == count)
        precondition(markSectionCount(in: capture.snapshot!) == 1)
    }
}

private func markSectionCount(in snapshot: ConfigScriptSnapshot) -> Int? {
    snapshot.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let header = bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian
            if UInt8(truncatingIfNeeded: header) == UInt8(OMNI_CONFIG_SECTION_MARKS) {
                return Int(UInt16(truncatingIfNeeded: header >> 16))
            }
            offset += MemoryLayout<UInt64>.size + Int(header >> 32)
        }
        return nil
    }
}

@MainActor
private func warmWindowDetailTextCaches(_ fixture: ScriptARCFixture, count: Int) {
    _ = fixture.controller.appInfoCache.info(for: fixture.token.pid) { _ in
        .init(name: "Cached audit application", bundleId: "test.omniwm.details", icon: nil, activationPolicy: .regular)
    }
    for offset in 0 ..< count {
        AXWindowService.storeTitleCacheEntry(
            windowId: UInt32(fixture.token.windowId + offset),
            title: "Cached audit window \(offset)"
        )
    }
}

private func notchedAuditMonitor(_ monitor: Monitor) -> Monitor {
    let notchHalfWidth: CGFloat = 80
    let notchHeight: CGFloat = 32
    let backingScale: CGFloat = 2
    let frame = monitor.frame
    let visibleFrame = CGRect(
        x: frame.minX, y: frame.minY, width: frame.width, height: frame.height - notchHeight
    )
    return Monitor(
        id: monitor.id, displayId: monitor.displayId, frame: frame, visibleFrame: visibleFrame, hasNotch: true,
        notchRange: (frame.midX - notchHalfWidth) ... (frame.midX + notchHalfWidth),
        notchHeight: notchHeight, backingScale: backingScale,
        name: monitor.name, displayUUID: monitor.displayUUID, isMain: monitor.isMain
    )
}

@MainActor
private func calibrateDetailPlatformReads() {
    let application = AXUIElementCreateApplication(getpid())
    var role: CFTypeRef?
    script_arc_begin()
    _ = AXUIElementCopyAttributeValue(application, kAXRoleAttribute as CFString, &role)
    _ = SkyLight.shared.getMainConnectionID()
    let screens = NSScreen.screens
    let bounds = CGDisplayBounds(CGMainDisplayID())
    script_arc_end()
    withExtendedLifetime((screens, bounds, role)) {}
}
