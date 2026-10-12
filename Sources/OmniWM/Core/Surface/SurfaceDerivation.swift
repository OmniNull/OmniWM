// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

enum SurfaceDerivation {
    private enum BorderFramePolicy {
        case complete
        case animation(previous: DesiredBorderSurface?)
    }

    @MainActor
    static func derive(world: WorldView) -> DesiredSurfaceScene {
        guard world.hasStartedServices else { return .empty }
        return DesiredSurfaceScene(
            border: deriveBorder(world: world),
            tabRails: world.tabRailInfos(),
            tabRailStyle: world.tabRailStyle,
            placeholders: world.nativeFullscreenPlaceholders(),
            bars: world.barSurfaces(),
            parkingEdgeMasks: deriveParkingEdgeMasks(monitors: world.monitors, spaceTopology: world.spaceTopology),
            niriColumns: world.niriColumnSummaries()
        )
    }

    static func deriveParkingEdgeMasks(
        monitors: [Monitor],
        spaceTopology: SpaceTopology
    ) -> [DesiredParkingEdgeMask] {
        let width: CGFloat = 1
        var masks: [DesiredParkingEdgeMask] = []
        masks.reserveCapacity(monitors.count * 2)

        for monitor in monitors {
            guard spaceTopology.isDisplayShowingFullscreenSpace(on: monitor) != true else { continue }
            let frame = monitor.visibleFrame
            guard !frame.isNull,
                  !frame.isInfinite,
                  frame.width >= width * 2,
                  frame.height > 0
            else { continue }

            masks.append(
                DesiredParkingEdgeMask(
                    key: ParkingEdgeMaskKey(monitorId: monitor.id, side: .left),
                    frame: CGRect(x: frame.minX, y: frame.minY, width: width, height: frame.height)
                )
            )
            masks.append(
                DesiredParkingEdgeMask(
                    key: ParkingEdgeMaskKey(monitorId: monitor.id, side: .right),
                    frame: CGRect(x: frame.maxX - width, y: frame.minY, width: width, height: frame.height)
                )
            )
        }

        return masks
    }

    @MainActor
    static func deriveBorder(world: WorldView) -> DesiredBorderSurface? {
        deriveBorder(world: world, framePolicy: .complete)
    }

    @MainActor
    static func deriveAnimationBorder(
        world: WorldView,
        previous: DesiredBorderSurface?
    ) -> DesiredBorderSurface? {
        deriveBorder(world: world, framePolicy: .animation(previous: previous))
    }

    @MainActor
    private static func deriveBorder(
        world: WorldView,
        framePolicy: BorderFramePolicy
    ) -> DesiredBorderSurface? {
        let config = world.borderConfig
        guard config.enabled else { return nil }
        guard let token = world.borderFocusToken,
              let entry = world.entry(for: token)
        else {
            return nil
        }
        guard !world.hasPendingNativeFullscreenTransition(for: token) else { return nil }
        guard !world.hasPendingWindowClose(for: entry) else { return nil }
        guard world.systemModalFocusToken != token else { return nil }
        guard world.suppressedFocusToken != token,
              !world.hasPendingNativeFullscreenTransition(in: entry.workspaceId),
              !world.isWindowFullscreenInLayout(token),
              world.isManagedWindowDisplayable(entry.token),
              world.isWorkspaceVisible(entry.workspaceId)
        else {
            return nil
        }
        guard let frame = borderFrame(
            for: entry,
            world: world,
            policy: framePolicy
        ),
            frame.width > 0, frame.height > 0
        else {
            return nil
        }
        return DesiredBorderSurface(token: entry.token, frame: frame, config: config)
    }

    @MainActor
    private static func borderFrame(
        for entry: WindowState,
        world: WorldView,
        policy: BorderFramePolicy
    ) -> CGRect? {
        switch policy {
        case .complete:
            return world.borderFrame(for: entry)
        case let .animation(previous):
            if let cached = world.cachedBorderFrame(for: entry) {
                return cached
            }
            guard previous?.token == entry.token else { return nil }
            return previous?.frame
        }
    }
}
