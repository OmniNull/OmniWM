// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import QuartzCore

struct ShellCurve: Equatable, Sendable {
    struct Segment: Equatable, Sendable {
        let control1: CGPoint
        let control2: CGPoint
        let end: CGPoint
    }

    static let custom: UInt8 = 255

    private static let presets: [[CGFloat]] = [
        [0, 0, 1, 1, 1, 1],
        [0.42, 0, 1, 1, 1, 1],
        [0, 0, 0.58, 1, 1, 1],
        [0.42, 0, 0.58, 1, 1, 1],
        [0.34, 1.56, 0.64, 1, 1, 1],
        [0.2, 0, 0, 1, 1, 1],
        [0.3, 0, 1, 1, 1, 1],
        [0, 0, 0, 1, 1, 1],
        [0.05, 0, 2.0 / 15.0, 0.06, 1.0 / 6.0, 0.4, 5.0 / 24.0, 0.82, 0.25, 1, 1, 1],
        [0.3, 0, 0.8, 0.15, 1, 1],
        [0.05, 0.7, 0.1, 1, 1, 1],
        [0.42, 1.67, 0.21, 0.9, 1, 1],
        [0.38, 1.21, 0.22, 1, 1, 1],
        [0.39, 1.29, 0.35, 0.98, 1, 1],
        [0.31, 0.94, 0.34, 1, 1, 1],
        [0.34, 0.8, 0.34, 1, 1, 1],
        [0.34, 0.88, 0.34, 1, 1, 1]
    ]

    let segments: [Segment]

    init?(points: [CGFloat]) {
        let points = points.count == 4 ? points + [1, 1] : points
        guard !points.isEmpty, points.count % 6 == 0 else { return nil }
        segments = stride(from: 0, to: points.count, by: 6).map { index in
            Segment(
                control1: CGPoint(x: points[index], y: points[index + 1]),
                control2: CGPoint(x: points[index + 2], y: points[index + 3]),
                end: CGPoint(x: points[index + 4], y: points[index + 5])
            )
        }
    }

    init?(wire: UInt8, custom: String?) {
        if wire == Self.custom {
            guard let custom else { return nil }
            self.init(points: custom.split(separator: ",").compactMap { Double($0).map { CGFloat($0) } })
        } else {
            guard wire > 0, Int(wire) <= Self.presets.count else { return nil }
            self.init(points: Self.presets[Int(wire) - 1])
        }
    }

    private init(segments: [Segment]) {
        self.segments = segments
    }

    var reversed: ShellCurve {
        var start = CGPoint.zero
        let points = segments.flatMap { segment in
            defer { start = segment.end }
            return [start, segment.control1, segment.control2]
        } + [segments[segments.count - 1].end]
        let mirrored = points.reversed().map { CGPoint(x: 1 - $0.x, y: 1 - $0.y) }
        return ShellCurve(segments: stride(from: 1, to: mirrored.count, by: 3).map {
            Segment(control1: mirrored[$0], control2: mirrored[$0 + 1], end: mirrored[$0 + 2])
        })
    }

    func timing() -> CAMediaTimingFunction {
        let first = segments[0].control1
        let last = segments[segments.count - 1].control2
        return CAMediaTimingFunction(controlPoints: Float(first.x), Float(first.y), Float(last.x), Float(last.y))
    }

    struct Keyframes {
        var times: [NSNumber] = [0]
        var progress: [CGFloat] = [0]
        var timings: [CAMediaTimingFunction] = []
    }

    var keyframes: Keyframes? {
        guard segments.count > 1 else { return nil }
        var start = CGPoint.zero
        var frames = Keyframes()
        for segment in segments {
            let width = max(segment.end.x - start.x, .ulpOfOne)
            let height = segment.end.y - start.y
            let normalize = { (point: CGPoint) in
                (Float((point.x - start.x) / width), Float(height == 0 ? 0 : (point.y - start.y) / height))
            }
            let (x1, y1) = normalize(segment.control1)
            let (x2, y2) = normalize(segment.control2)
            frames.timings.append(CAMediaTimingFunction(controlPoints: x1, y1, x2, y2))
            frames.times.append(NSNumber(value: Double(segment.end.x)))
            frames.progress.append(segment.end.y)
            start = segment.end
        }
        return frames
    }
}

extension ShellAnimation {
    func keyframes(_ keyPath: String, from: Any?, on layer: CALayer) -> CAKeyframeAnimation? {
        keyframes(keyPath, from: from, to: layer.value(forKeyPath: keyPath))
    }

    func keyframes(_ keyPath: String, from: Any?, to: Any?) -> CAKeyframeAnimation? {
        guard case let .ease(seconds) = motion, let frames = curve?.keyframes else { return nil }
        var values: [Any] = []
        for progress in frames.progress {
            guard let value = ShellCurve.mix(from, to, progress) else { return nil }
            values.append(value)
        }
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = frames.times
        animation.timingFunctions = frames.timings
        animation.duration = seconds / speed
        return animation
    }
}

extension ShellCurve {
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)

    static func mix(_ from: Any?, _ to: Any?, _ progress: CGFloat) -> Any? {
        let mix = { (from: CGFloat, to: CGFloat) in from + (to - from) * progress }
        switch (from, to) {
        case let (from as CGRect, to as CGRect):
            return NSValue(rect: CGRect(
                x: mix(from.minX, to.minX),
                y: mix(from.minY, to.minY),
                width: mix(from.width, to.width),
                height: mix(from.height, to.height)
            ))
        case let (from as CGPoint, to as CGPoint):
            return NSValue(point: CGPoint(x: mix(from.x, to.x), y: mix(from.y, to.y)))
        case let (from as CGSize, to as CGSize):
            return NSValue(size: CGSize(width: mix(from.width, to.width), height: mix(from.height, to.height)))
        case let (from as CATransform3D, to as CATransform3D):
            var result = from
            withUnsafeMutableBytes(of: &result) { result in
                withUnsafeBytes(of: to) { to in
                    let start = result.bindMemory(to: CGFloat.self)
                    let end = to.bindMemory(to: CGFloat.self)
                    for index in start.indices {
                        start[index] = mix(start[index], end[index])
                    }
                }
            }
            return NSValue(caTransform3D: result)
        case let (from as NSNumber, to as NSNumber):
            return NSNumber(value: Double(mix(CGFloat(from.doubleValue), CGFloat(to.doubleValue))))
        default:
            guard let from = color(from), let to = color(to),
                  let start = from.components, let end = to.components, start.count == end.count,
                  let space = sRGB
            else {
                return nil
            }
            return CGColor(colorSpace: space, components: zip(start, end).map { mix($0, $1) })
        }
    }

    private static func color(_ value: Any?) -> CGColor? {
        guard let value, CFGetTypeID(value as CFTypeRef) == CGColor.typeID else { return nil }
        let color = unsafeDowncast(value as AnyObject, to: CGColor.self)
        return sRGB.flatMap { color.converted(to: $0, intent: .defaultIntent, options: nil) }
    }
}

extension ShellCurve {
    func value(at time: CGFloat) -> CGFloat {
        var start = CGPoint.zero
        for segment in segments {
            defer { start = segment.end }
            guard time <= segment.end.x || segment == segments.last else { continue }
            let width = max(segment.end.x - start.x, .ulpOfOne)
            let target = min(max((time - start.x) / width, 0), 1)
            let x1 = (segment.control1.x - start.x) / width
            let x2 = (segment.control2.x - start.x) / width
            var low: CGFloat = 0
            var high: CGFloat = 1
            var parameter = target
            for _ in 0 ..< 12 {
                let x = Self.cubic(parameter, 0, x1, x2, 1) - target
                guard abs(x) > 1e-9 else { break }
                if x > 0 { high = parameter } else { low = parameter }
                let slope = Self.slope(parameter, 0, x1, x2, 1)
                let next = parameter - x / slope
                parameter = slope > .ulpOfOne && next >= low && next <= high ? next : (low + high) / 2
            }
            return Self.cubic(parameter, start.y, segment.control1.y, segment.control2.y, segment.end.y)
        }
        return 1
    }

    private static func cubic(_ at: CGFloat, _ p0: CGFloat, _ p1: CGFloat, _ p2: CGFloat, _ p3: CGFloat) -> CGFloat {
        let rest = 1 - at
        return rest * rest * rest * p0 + 3 * rest * rest * at * p1 + 3 * rest * at * at * p2 + at * at * at * p3
    }

    private static func slope(_ at: CGFloat, _ p0: CGFloat, _ p1: CGFloat, _ p2: CGFloat, _ p3: CGFloat) -> CGFloat {
        let rest = 1 - at
        return 3 * rest * rest * (p1 - p0) + 6 * rest * at * (p2 - p1) + 3 * at * at * (p3 - p2)
    }
}

enum ShellStretch {
    static let rate: CGFloat = 120
    private static let limit: CGFloat = 0.35
    private static let stiffness: CGFloat = 200
    private static let damping: CGFloat = 16

    static func deforms(positions: [CGPoint], amount: CGFloat) -> [CGAffineTransform] {
        let scale = amount / 10000
        let dt = 1 / rate
        var matrix = (a: CGFloat(1), b: CGFloat(0), d: CGFloat(1))
        var velocity = (a: CGFloat(0), b: CGFloat(0), d: CGFloat(0))
        var result = [CGAffineTransform.identity]
        for index in positions.indices.dropFirst() {
            let move = CGPoint(
                x: (positions[index].x - positions[index - 1].x) / dt,
                y: (positions[index].y - positions[index - 1].y) / dt
            )
            let speed = hypot(move.x, move.y)
            var target = (a: CGFloat(1), b: CGFloat(0), d: CGFloat(1))
            if speed > 5 {
                let stretch = 1 + min(speed * scale, limit)
                let compress = 1 / stretch
                let cos = move.x / speed
                let sin = move.y / speed
                target = (
                    stretch * cos * cos + compress * sin * sin,
                    (stretch - compress) * cos * sin,
                    stretch * sin * sin + compress * cos * cos
                )
            }
            let damp = 1 / (1 + damping * dt)
            velocity.a = (velocity.a - stiffness * (matrix.a - target.a) * dt) * damp
            velocity.b = (velocity.b - stiffness * (matrix.b - target.b) * dt) * damp
            velocity.d = (velocity.d - stiffness * (matrix.d - target.d) * dt) * damp
            matrix.a += velocity.a * dt
            matrix.b += velocity.b * dt
            matrix.d += velocity.d * dt
            result.append(CGAffineTransform(a: matrix.a, b: matrix.b, c: matrix.b, d: matrix.d, tx: 0, ty: 0))
        }
        if let last = result.indices.last {
            result[last] = .identity
        }
        return result
    }
}

struct ShellLoop: Equatable, Sendable {
    struct Channel: Equatable, Sendable {
        let name: String
        let from: CGFloat
        let to: CGFloat
        let duration: CFTimeInterval
    }

    static let keys = ["loop.dx", "loop.dy", "loop.rotate"]

    let channels: [Channel]

    init?(_ spec: String) {
        channels = spec.split(separator: ";").compactMap { part in
            let fields = part.split(separator: " ")
            guard fields.count == 4, Self.keys.contains("loop.\(fields[0])"), let from = Double(fields[1]),
                  let to = Double(fields[2]), let duration = Double(fields[3]), duration > 0
            else {
                return nil
            }
            return Channel(name: String(fields[0]), from: from, to: to, duration: duration)
        }
        guard !channels.isEmpty else { return nil }
    }

    func animations(size: CGSize) -> [(key: String, animation: CAAnimation)] {
        channels.map { channel in
            let animation: CAPropertyAnimation
            if channel.name == "rotate" {
                let keyframes = CAKeyframeAnimation(keyPath: "transform")
                let steps = max(Int((abs(channel.to - channel.from) / 5).rounded(.up)), 4)
                let center = CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0)
                keyframes.values = (0 ... steps).map { step in
                    let angle = (channel.from + (channel.to - channel.from) * CGFloat(step) / CGFloat(steps)) * .pi /
                        180
                    let turn = CATransform3DConcat(
                        CATransform3DInvert(center),
                        CATransform3DMakeRotation(angle, 0, 0, 1)
                    )
                    return NSValue(caTransform3D: CATransform3DConcat(turn, center))
                }
                animation = keyframes
            } else {
                let basic = CABasicAnimation(keyPath: channel.name == "dx" ? "position.x" : "position.y")
                basic.fromValue = channel.from
                basic.toValue = channel.to
                animation = basic
            }
            animation.isAdditive = true
            animation.duration = channel.duration
            animation.repeatCount = .infinity
            return ("loop.\(channel.name)", animation)
        }
    }
}

extension ShellAnimation {
    static let trailFactor: CGFloat = 1.5

    func trail(
        from old: CGRect,
        to new: CGRect,
        origin: CGPoint = .zero
    ) -> (position: CAKeyframeAnimation, bounds: CAKeyframeAnimation)? {
        guard case let .ease(seconds) = motion, old != new,
              let curve = curve ?? ShellCurve(wire: 4, custom: nil)
        else {
            return nil
        }
        let lead = seconds / speed
        let total = lead * Self.trailFactor
        let steps = max(Int((total * 60).rounded(.up)), 2)
        let edge = { (from: CGFloat, to: CGFloat, time: CGFloat, leads: Bool) in
            from + (to - from) * curve.value(at: min(time / (leads ? lead : total), 1))
        }
        var positions: [NSValue] = []
        var sizes: [NSValue] = []
        for step in 0 ... steps {
            let time = total * CGFloat(step) / CGFloat(steps)
            let right = new.minX >= old.minX
            let down = new.minY >= old.minY
            let minX = edge(old.minX, new.minX, time, !right)
            let maxX = edge(old.maxX, new.maxX, time, right)
            let minY = edge(old.minY, new.minY, time, !down)
            let maxY = edge(old.maxY, new.maxY, time, down)
            positions.append(NSValue(point: CGPoint(x: minX, y: minY)))
            sizes.append(NSValue(rect: CGRect(origin: origin, size: CGSize(width: maxX - minX, height: maxY - minY))))
        }
        let keyTimes = (0 ... steps).map { NSNumber(value: Double($0) / Double(steps)) }
        let make = { (keyPath: String, values: [NSValue]) in
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = values
            animation.keyTimes = keyTimes
            animation.duration = total
            return animation
        }
        return (make("position", positions), make("bounds", sizes))
    }
}
