// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics

final class WindowCornerContour: Equatable, Sendable {
    private struct Vertex: Sendable {
        let point: CGPoint
        let outward: CGVector
    }

    private let corners: [[Vertex]]
    private let extent: CGFloat

    init?(image: CGImage, observedSize: CGSize) {
        guard observedSize.width > 0, observedSize.height > 0 else { return nil }
        let scale = CGFloat(image.width) / observedSize.width
        guard scale >= 1, scale <= 4,
              abs(CGFloat(image.height) - observedSize.height * scale) <= 1
        else { return nil }
        let count = min(256, image.width / 2, image.height / 2)
        guard count > 1 else { return nil }
        var corners: [[Vertex]] = []
        var extent: CGFloat = 0
        for index in 0 ..< 4 {
            let right = index == 1 || index == 2
            let bottom = index >= 2
            let rect = CGRect(
                x: right ? image.width - count : 0,
                y: bottom ? image.height - count : 0,
                width: count, height: count
            )
            guard let crop = image.cropping(to: rect),
                  let corner = Self.sample(crop, count: count, right: right, bottom: bottom, scale: scale)
            else { return nil }
            corners.append(corner.vertices)
            extent = max(extent, corner.extent)
        }
        self.corners = corners
        self.extent = extent
    }

    private struct Corner {
        let vertices: [Vertex]
        let extent: CGFloat
    }

    private static func sample(
        _ crop: CGImage, count: Int, right: Bool, bottom: Bool, scale: CGFloat
    ) -> Corner? {
        var alpha = [UInt8](repeating: 0, count: count * count)
        let drew = alpha.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress, width: count, height: count,
                bitsPerComponent: 8, bytesPerRow: count, space: nil,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.alphaOnly.rawValue)
            ) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: count, height: count))
            return true
        }
        guard drew else { return nil }
        func value(_ x: Int, _ y: Int) -> UInt8 {
            alpha[(bottom ? count - 1 - y : y) * count + (right ? count - 1 - x : x)]
        }
        guard (0 ..< count).allSatisfy({ value(count - 1, $0) == 255 && value($0, count - 1) == 255 }),
              let topEnd = (0 ..< count).first(where: { value($0, 0) == 255 }),
              let leftEnd = (0 ..< count).first(where: { value(0, $0) == 255 })
        else { return nil }
        let reach = CGFloat(max(topEnd, leftEnd) + 1) / scale
        var points = [CGPoint(x: reach, y: 0)]
        for y in 0 ... leftEnd {
            guard let x = (0 ..< count).first(where: { value($0, y) >= 128 }) else { return nil }
            let before = x == 0 ? 0 : CGFloat(value(x - 1, y))
            let after = CGFloat(value(x, y))
            let edge = max(0, CGFloat(x) - 0.5 + (127.5 - before) / (after - before))
            points.append(CGPoint(x: edge / scale, y: (CGFloat(y) + 0.5) / scale))
        }
        points.append(CGPoint(x: 0, y: reach))
        if topEnd == 0, leftEnd == 0 { points = [.zero] }
        return Corner(vertices: vertices(from: points), extent: reach)
    }

    private static func vertices(from points: [CGPoint]) -> [Vertex] {
        points.indices.map { index in
            let point = points[index]
            let previous = index > 0 ? points[index - 1] : CGPoint(x: point.x + 1, y: point.y)
            let next = index + 1 < points.count ? points[index + 1] : CGPoint(x: point.x, y: point.y + 1)
            func normal(from start: CGPoint, to end: CGPoint) -> CGVector {
                let dx = end.x - start.x
                let dy = end.y - start.y
                let length = max(hypot(dx, dy), .leastNonzeroMagnitude)
                return CGVector(dx: -dy / length, dy: dx / length)
            }
            let incoming = normal(from: previous, to: point)
            let outgoing = normal(from: point, to: next)
            let divisor = max(0.5, 1 + incoming.dx * outgoing.dx + incoming.dy * outgoing.dy)
            return Vertex(point: point, outward: CGVector(
                dx: (incoming.dx + outgoing.dx) / divisor,
                dy: (incoming.dy + outgoing.dy) / divisor
            ))
        }
    }

    static func == (lhs: WindowCornerContour, rhs: WindowCornerContour) -> Bool {
        lhs === rhs
    }

    func path(in rect: CGRect, outset: CGFloat = 0) -> CGPath {
        let path = CGMutablePath()
        let scale = min(1, rect.width / (2 * extent), rect.height / (2 * extent))
        for index in [0, 3, 2, 1] {
            let right = index == 1 || index == 2
            let bottom = index >= 2
            let vertices = corners[index]
            for offset in vertices.indices {
                let vertex = vertices[(index == 1 || index == 3) ? vertices.count - 1 - offset : offset]
                let x = vertex.point.x * scale + vertex.outward.dx * outset
                let y = vertex.point.y * scale + vertex.outward.dy * outset
                let point = CGPoint(x: right ? rect.maxX - x : rect.minX + x, y: bottom ? rect.minY + y : rect.maxY - y)
                if path.isEmpty { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
        path.closeSubpath()
        return path
    }
}
