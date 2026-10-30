// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Metal
@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
final class ShellGlassFrameProbeTests: XCTestCase {
    private struct Frame {
        let name: String
        let size: CGSize
        let shape: ShellGlassShape
        let blend: CGFloat
    }

    private struct Image {
        let bytes: [UInt8]
        let width: Int
        let height: Int
        let scale: Int

        func alpha(_ x: CGFloat, _ y: CGFloat) -> Int {
            let column = min(max(Int(x * CGFloat(scale)), 0), width - 1)
            let row = min(max(Int(y * CGFloat(scale)), 0), height - 1)
            return Int(bytes[(row * width + column) * 4 + 3])
        }
    }

    private struct Grid {
        var count = 0
        var nonzero = 0
        var maximum = 0
        var first: [Int] = []

        var record: [String: Any] {
            ["sampleCount": count, "nonzeroCount": nonzero, "maximumAlpha": maximum, "firstNonzero": first]
        }
    }

    private var frames: [Frame] {
        var values = [
            Frame(name: "supported96", size: CGSize(width: 96, height: 96), shape: ShellGlassShape(
                slot: 1, kind: 2, rect: CGRect(x: -64, y: -64, width: 224, height: 224),
                radius: 88, thickness: 72
            ), blend: 8),
            Frame(name: "c7-large256", size: CGSize(width: 256, height: 256), shape: ShellGlassShape(
                slot: 1, kind: 2, rect: CGRect(x: -48, y: -48, width: 352, height: 352),
                radius: 88, thickness: 60
            ), blend: 8),
            Frame(name: "display1920", size: CGSize(width: 1920, height: 1080), shape: ShellGlassShape(
                slot: 1, kind: 2, rect: CGRect(x: -100, y: -100, width: 2120, height: 1280),
                radius: 136.07, thickness: 110.8
            ), blend: 35.1),
            Frame(name: "c1-thin160", size: CGSize(width: 160, height: 120), shape: ShellGlassShape(
                slot: 1, kind: 2, rect: CGRect(x: -80, y: -80, width: 320, height: 280),
                radius: 100.5, thickness: 80.5
            ), blend: 26)
        ]
        let size = CGSize(width: 1920, height: 1080)
        let thin: CGFloat = 10.8, strip: CGFloat = 62.1, inner: CGFloat = 25.27, blend: CGFloat = 35.1
        let thickness = 2 * blend + strip + 2 * inner
        for edge in ["left", "right", "ftop", "fbottom"] {
            let left = edge == "left" ? strip : thin
            let right = edge == "right" ? strip : thin
            let top = edge == "ftop" ? strip : thin
            let bottom = edge == "fbottom" ? strip : thin
            let hole = CGRect(x: left, y: top, width: size.width - left - right, height: size.height - top - bottom)
            values.append(Frame(name: "f1-" + edge, size: size, shape: ShellGlassShape(
                slot: 1, kind: 2, rect: hole.insetBy(dx: -thickness, dy: -thickness),
                radius: thickness + inner, thickness: thickness
            ), blend: blend))
        }
        return values
    }

    private func render(_ layer: CALayer, frame: Frame, scale: Int) throws -> Image {
        let width = Int(frame.size.width) * scale, height = Int(frame.size.height) * scale
        let root = CALayer()
        root.frame = CGRect(x: 0, y: 0, width: width, height: height)
        root.isGeometryFlipped = true
        let holder = CALayer()
        holder.anchorPoint = .zero
        holder.bounds = CGRect(origin: .zero, size: frame.size)
        holder.setAffineTransform(CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        root.addSublayer(holder)
        holder.addSublayer(layer)
        defer { layer.removeFromSuperlayer() }
        let renderer = try ShellOffscreenRenderer(root: root, width: width, height: height)
        return try Image(bytes: renderer.render(), width: width, height: height, scale: scale)
    }

    private func body(_ frame: Frame, alpha: CGFloat) throws -> ShellGlassBody {
        let recipe = try XCTUnwrap(ShellGlassRecipe("glass:\(frame.blend):-1:0:0:0"))
        let body = ShellGlassBody()
        body.apply(size: frame.size, shapes: [frame.shape], recipe: recipe, paint: ShellLayerPaint(
            fill: CGColor(gray: 1, alpha: alpha), border: nil, borderWidth: 0, radius: 0, opacity: 1, scale: 1,
            shadow: ShellLayerScene.clear, shadowRadius: 0, blurRadius: 0, saturation: 1
        ), animation: nil)
        XCTAssertTrue(body.nativeAvailable, body.failure ?? "Native frame was rejected")
        let part = try XCTUnwrap(body.elements[1][.init(slot: 1, part: 1)])
        XCTAssertEqual(part.frame, frame.shape.rect.insetBy(dx: frame.shape.thickness, dy: frame.shape.thickness))
        XCTAssertEqual(part.cornerRadius, frame.shape.radius - frame.shape.thickness, accuracy: 1e-9)
        XCTAssertEqual(part.value(forKey: "operation") as? String, "subtraction")
        return body
    }

    private func coverage(_ frame: Frame) -> CALayer {
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: frame.size)
        var containers: [Int32: CALayer] = [:]
        ShellGlassBody.reconcileContainers([frame.shape], elements: &containers, motion: nil)
        for container in containers.values { root.addSublayer(container) }
        for part in ShellGlassBody.parts(for: [frame.shape]).mask {
            let layer: CALayer
            if part.corner {
                let corner = CAShapeLayer()
                corner.path = ShellGlassBody.cornerPath()
                corner.fillColor = CGColor(gray: 1, alpha: 1)
                layer = corner
            } else {
                layer = CALayer()
                layer.backgroundColor = CGColor(gray: 1, alpha: 1)
            }
            layer.anchorPoint = .zero
            layer.cornerCurve = .circular
            part.geometry.apply(to: layer, motion: nil, track: part.track)
            (part.container.flatMap { containers[$0] } ?? root).addSublayer(layer)
        }
        return root
    }

    private func reference(_ frame: Frame) -> CALayer {
        let shape = frame.shape
        let path = CGMutablePath()
        path.addRoundedRect(in: shape.rect, cornerWidth: shape.radius, cornerHeight: shape.radius)
        let hole = shape.rect.insetBy(dx: shape.thickness, dy: shape.thickness)
        let radius = max(0, shape.radius - shape.thickness)
        path.addRoundedRect(in: hole, cornerWidth: radius, cornerHeight: radius)
        let layer = CAShapeLayer()
        layer.frame = CGRect(origin: .zero, size: frame.size)
        layer.fillColor = CGColor(gray: 1, alpha: 1)
        layer.fillRule = .evenOdd
        layer.path = path
        return layer
    }

    private func raw(_ frame: Frame, alpha: CGFloat, merge: Bool? = nil, culling: Bool? = nil) throws -> CALayer {
        let capability = ShellGlassCapability.shared
        let body = try XCTUnwrap(capability.bodyClass).init()
        body.anchorPoint = .zero
        body.frame = CGRect(origin: .zero, size: frame.size)
        body.setValue(2 * frame.blend, forKey: "smoothness")
        if let merge {
            guard type(of: body).instancesRespond(to: NSSelectorFromString("setMergeElements:")) else {
                throw XCTSkip("CASDFLayer.mergeElements is unavailable")
            }
            body.setValue(merge, forKey: "mergeElements")
        }
        if let culling {
            guard type(of: body).instancesRespond(to: NSSelectorFromString("setExperimentalCulling:")) else {
                throw XCTSkip("CASDFLayer.experimentalCulling is unavailable")
            }
            body.setValue(culling, forKey: "experimentalCulling")
        }
        body.setValue(capability.effect(.fill, values: [.color: CGColor(gray: 1, alpha: alpha)]), forKey: "effect")
        for part in ShellGlassBody.parts(for: [frame.shape]).sdf {
            let element = try XCTUnwrap(capability.elementClass).init()
            element.anchorPoint = .zero
            element.setValue("bounds", forKey: "mode")
            element.setValue(part.subtract ? "subtraction" : "union", forKey: "operation")
            part.geometry.apply(to: element, motion: nil, track: part.track)
            body.addSublayer(element)
        }
        return body
    }

    private func grid(_ image: Image, frame: Frame) -> Grid {
        let hole = frame.shape.rect.insetBy(dx: frame.shape.thickness, dy: frame.shape.thickness)
        let inset = max(4, frame.shape.radius - frame.shape.thickness + 4)
        let core = hole.insetBy(dx: inset, dy: inset)
        var result = Grid()
        for y in stride(from: Int(ceil(core.minY)), to: Int(floor(core.maxY)), by: 8) {
            for x in stride(from: Int(ceil(core.minX)), to: Int(floor(core.maxX)), by: 8) {
                let alpha = image.alpha(CGFloat(x), CGFloat(y))
                result.count += 1
                result.maximum = max(result.maximum, alpha)
                if alpha > 0 {
                    result.nonzero += 1
                    if result.first.isEmpty { result.first = [x, y] }
                }
            }
        }
        return result
    }

    private func summary(_ image: Image, frame: Frame) -> [String: Any] {
        let hole = frame.shape.rect.insetBy(dx: frame.shape.thickness, dy: frame.shape.thickness)
        let y = frame.size.height / 2
        let offsets: [CGFloat] = [1, 8, 16, 32, 48, 64, 96, 128, 256]
        return [
            "centreAlpha": image.alpha(frame.size.width / 2, y),
            "edgeAlpha": image.alpha(0, y),
            "clearHoleGrid": grid(image, frame: frame).record,
            "insideRow": offsets.filter { $0 < hole.width / 2 }.map {
                ["distanceFromHoleEdge": Double($0), "alpha": image.alpha(hole.minX + $0, y)]
            }
        ]
    }

    func testStaticFrameCoverageAndNativeSubtractionProbe() throws {
        _ = try XCTUnwrap(ShellShaderGPU.device, "The frame gate requires Metal")
        XCTAssertNil(ShellGlassCapability.shared.missing)
        var records: [[String: Any]] = []
        for frame in frames {
            XCTAssertTrue(ShellGlassBody.nativeFrameCoversCanvas(frame.shape, canvas: frame.size, blend: frame.blend))
            for scale in [1, 2] {
                records.append(try probe(frame, scale: scale))
            }
        }
        if let output = ProcessInfo.processInfo.environment["OMNI_F1_FRAME_PROBE_OUT"] {
            let target = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONSerialization.data(
                withJSONObject: [
                    "renderer": "CARenderer; WindowServer applicability untested",
                    "system": ProcessInfo.processInfo.operatingSystemVersionString,
                    "frames": records
                ],
                options: [.prettyPrinted, .sortedKeys]
            ).write(to: target)
        }
    }

    private func probe(_ frame: Frame, scale: Int) throws -> [String: Any] {
        let mask = try render(coverage(frame), frame: frame, scale: scale)
        let path = try render(reference(frame), frame: frame, scale: scale)
        XCTAssertEqual(mask.alpha(frame.size.width / 2, frame.size.height / 2), 0)
        XCTAssertEqual(path.alpha(frame.size.width / 2, frame.size.height / 2), 0)
        var entry: [String: Any] = [
            "name": frame.name,
            "scale": scale,
            "canvas": [frame.size.width, frame.size.height],
            "outer": [frame.shape.rect.minX, frame.shape.rect.minY, frame.shape.rect.width, frame.shape.rect.height],
            "thickness": frame.shape.thickness,
            "outerRadius": frame.shape.radius,
            "blend": frame.blend,
            "baseMask": summary(mask, frame: frame),
            "evenOddReference": summary(path, frame: frame)
        ]
        for alpha: CGFloat in [1, 0.36] {
            entry["alpha\(alpha)"] = try probeFill(frame, scale: scale, alpha: alpha, mask: mask)
        }
        return entry
    }

    private func probeFill(_ frame: Frame, scale: Int, alpha: CGFloat, mask: Image) throws -> [String: Any] {
        let body = try body(frame, alpha: alpha)
        let full = try render(body.layer, frame: frame, scale: scale)
        let children = body.layer.sublayers ?? []
        let visibility = children.map(\.isHidden)
        for child in children { child.isHidden = child !== body.sdfLayers[1] }
        let fill = try render(body.layer, frame: frame, scale: scale)
        for (child, hidden) in zip(children, visibility) { child.isHidden = hidden }
        let bare = try render(raw(frame, alpha: alpha), frame: frame, scale: scale)
        if frame.name != "c7-large256" {
            for (label, image) in [("product-fill", fill), ("bare-native", bare)] {
                let sampled = grid(image, frame: frame)
                XCTAssertGreaterThan(sampled.count, 0)
                XCTAssertEqual(sampled.nonzero, 0, "\(frame.name) \(scale)x \(label): \(sampled.record)")
                XCTAssertEqual(image.alpha(frame.size.width / 2, frame.size.height / 2), 0)
            }
        }
        let merged = try render(raw(frame, alpha: alpha, merge: true), frame: frame, scale: scale)
        let uncull = try render(raw(frame, alpha: alpha, culling: false), frame: frame, scale: scale)
        if scale == 1, alpha == 0.36,
           frame.name == "display1920" || frame.name == "c7-large256" || frame.name.hasPrefix("f1-")
        {
            try save(full, name: frame.name + "-body")
            try save(mask, name: frame.name + "-base-mask")
            try save(bare, name: frame.name + "-bare-native")
        }
        return [
            "fullBody": summary(full, frame: frame),
            "bodyFillOnly": summary(fill, frame: frame),
            "bareNative": summary(bare, frame: frame),
            "mergeElementsTrue": summary(merged, frame: frame),
            "experimentalCullingFalse": summary(uncull, frame: frame),
            "bodyAndBareFillIdentical": fill.bytes == bare.bytes
        ]
    }

    private func save(_ image: Image, name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["OMNI_F1_FRAME_PROBE_OUT"] else { return }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(image.bytes) as CFData))
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try XCTUnwrap(CGImage(
            width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: image.width * 4,
            space: colorSpace, bitmapInfo: CGBitmapInfo.byteOrder32Little
                .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let target = URL(fileURLWithPath: output).deletingLastPathComponent().appendingPathComponent(name + ".png")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: target)
    }
}
