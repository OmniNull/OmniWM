// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics

enum NiriPictureContent {
    case image(CGImage)
    case preview(OverviewPreviewFrame)

    var image: CGImage? {
        if case let .image(image) = self { image } else { nil }
    }

    var preview: OverviewPreviewFrame? {
        if case let .preview(frame) = self { frame } else { nil }
    }

    var layerContents: AnyObject {
        switch self {
        case let .image(image): image
        case let .preview(frame): frame.surface
        }
    }

    var contentsRect: CGRect {
        preview?.contentsRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    func matches(_ other: Self?) -> Bool {
        switch (self, other) {
        case let (.image(lhs), .image(rhs)): lhs === rhs
        case let (.preview(lhs), .preview(rhs)): lhs === rhs
        default: false
        }
    }
}
