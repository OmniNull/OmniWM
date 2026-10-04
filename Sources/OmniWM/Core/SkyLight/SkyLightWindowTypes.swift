// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

enum SkyLightWindowOrder: Int32 {
    case below = -1
    case out = 0
    case above = 1
}

enum DisplaySpacesMode: Equatable, Sendable {
    case enabled
    case disabled
    case unavailable
}

struct WindowCornerRadii: Equatable, Sendable {
    var topLeft: CGFloat
    var topRight: CGFloat
    var bottomLeft: CGFloat
    var bottomRight: CGFloat

    init(topLeft: CGFloat, topRight: CGFloat, bottomLeft: CGFloat, bottomRight: CGFloat) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomLeft = bottomLeft
        self.bottomRight = bottomRight
    }

    init(uniform radius: CGFloat) {
        self.init(topLeft: radius, topRight: radius, bottomLeft: radius, bottomRight: radius)
    }

    static let zero = WindowCornerRadii(uniform: 0)

    var isAllZero: Bool {
        topLeft == 0 && topRight == 0 && bottomLeft == 0 && bottomRight == 0
    }

    func normalized(to size: CGSize) -> WindowCornerRadii {
        let radii = nonnegative
        guard size.width > 0, size.height > 0 else { return .zero }

        var scale: CGFloat = 1
        scale = min(scale, ratio(limit: size.width, sum: radii.topLeft + radii.topRight))
        scale = min(scale, ratio(limit: size.width, sum: radii.bottomLeft + radii.bottomRight))
        scale = min(scale, ratio(limit: size.height, sum: radii.topLeft + radii.bottomLeft))
        scale = min(scale, ratio(limit: size.height, sum: radii.topRight + radii.bottomRight))
        guard scale < 1 else { return radii }

        return WindowCornerRadii(
            topLeft: radii.topLeft * scale,
            topRight: radii.topRight * scale,
            bottomLeft: radii.bottomLeft * scale,
            bottomRight: radii.bottomRight * scale
        )
    }

    var nonnegative: WindowCornerRadii {
        WindowCornerRadii(
            topLeft: Self.nonnegative(topLeft),
            topRight: Self.nonnegative(topRight),
            bottomLeft: Self.nonnegative(bottomLeft),
            bottomRight: Self.nonnegative(bottomRight)
        )
    }

    private func ratio(limit: CGFloat, sum: CGFloat) -> CGFloat {
        sum > 0 ? limit / sum : 1
    }

    private static func nonnegative(_ value: CGFloat) -> CGFloat {
        value.isFinite ? max(value, 0) : 0
    }
}

enum WindowCornerSource: Equatable, Sendable {
    case resolved
    case raw
}

struct WindowCornerSample: Equatable, Sendable {
    let radii: WindowCornerRadii
    let observedSize: CGSize
    let source: WindowCornerSource
}

struct ManagedDisplaySpaces: Sendable {
    let displayIdentifier: String
    let spaceIds: [UInt64]
    let currentSpaceId: UInt64
    let fullscreenSpaceIds: Set<UInt64>
}

enum NativeSpaceWindowInventoryResult: Equatable, Sendable {
    case unavailable
    case queryFailed
    case authoritative([UInt64: [WindowServerInfo]])
}

enum CGSEventType: UInt32 {
    case secureEventInputStarted = 752
    case secureEventInputStopped = 753
    case windowClosed = 804
    case windowMoved = 806
    case windowResized = 807
    case windowOrderChanged = 808
    case windowTitleChanged = 1322
    case spaceWindowCreated = 1325
    case spaceWindowDestroyed = 1326
    case frontmostApplicationChanged = 1508
    case all = 0xFFFF_FFFF
}

struct WindowServerInfo: Equatable, Sendable {
    let id: UInt32
    let pid: Int32
    let level: Int32
    let frame: CGRect
    var tags: UInt64 = 0
    var attributes: UInt32 = 0
    var parentId: UInt32 = 0
    var title: String?
    var isOrderedIn: Bool?

    static func hasDocumentTag(_ tags: UInt64) -> Bool {
        (tags & 0x1) != 0
    }

    static func hasFloatingTag(_ tags: UInt64) -> Bool {
        (tags & 0x2) != 0
    }

    static func hasModalTag(_ tags: UInt64) -> Bool {
        (tags & 0x8000_0000) != 0
    }

    var hasDocumentTag: Bool {
        Self.hasDocumentTag(tags)
    }

    var hasFloatingTag: Bool {
        Self.hasFloatingTag(tags)
    }

    var hasModalTag: Bool {
        Self.hasModalTag(tags)
    }

    var hasParentWindow: Bool {
        parentId != 0
    }

    var hasTransientSurfaceEvidence: Bool {
        hasParentWindow || (hasFloatingTag && !hasDocumentTag)
    }
}
