// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics

extension ShellWidgetHost {
    func stops(of instance: InstanceState, on key: ShellBarKey, lane: ShellLane) -> [CGFloat]? {
        instance.parts.stops(
            in: instance.size,
            vertical: bars[key]?.style.vertical == true,
            keepsEnd: lane == .trailing
        )
    }

    func followedTarget(on key: ShellBarKey) -> String? {
        bars[key]?.workspaces.first(where: \.focused).map { "workspace \($0.id)" }
    }

    func syncFollowedTargets() {
        for state in widgets.values {
            for (key, instance) in state.instances {
                instance.surface?.followedTarget = followedTarget(on: key)
            }
        }
    }
}
