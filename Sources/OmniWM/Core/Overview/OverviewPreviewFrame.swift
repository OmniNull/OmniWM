// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import CoreVideo
import IOSurface

final class OverviewPreviewFrame: @unchecked Sendable {
    private let pixelBuffer: CVPixelBuffer
    let surface: IOSurface
    let contentsRect: CGRect

    init?(pixelBuffer: CVPixelBuffer, contentRect: CGRect? = nil, scaleFactor: CGFloat = 1) {
        guard let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return nil }
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        guard width > 0, height > 0, scaleFactor.isFinite, scaleFactor > 0 else { return nil }
        if let contentRect {
            let normalized = CGRect(
                x: contentRect.minX * scaleFactor / width,
                y: contentRect.minY * scaleFactor / height,
                width: contentRect.width * scaleFactor / width,
                height: contentRect.height * scaleFactor / height
            ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !normalized.isNull, !normalized.isEmpty else { return nil }
            contentsRect = normalized
        } else {
            contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        self.surface = surface
        self.pixelBuffer = pixelBuffer
    }
}

extension OverviewPreviewFrame {
    func covers(_ request: OverviewPreviewRequest) -> Bool {
        CGFloat(surface.width) * contentsRect.width + 1 >= CGFloat(request.pixelWidth)
            && CGFloat(surface.height) * contentsRect.height + 1 >= CGFloat(request.pixelHeight)
    }
}
