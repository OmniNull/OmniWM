// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
enum OmniWMBrandMark {
    private static let statusTemplateSource = resourceImage(named: "OmniWMStatusTemplate", isTemplate: true)
    private static let launchLockup = resourceImage(named: "OmniWMLaunchLockup", isTemplate: false)
    private static var statusTemplates: [CGFloat: NSImage] = [:]

    static func statusItemImage(pointSize: CGFloat) -> NSImage {
        let template: NSImage
        if let cached = statusTemplates[pointSize] {
            template = cached
        } else {
            guard let image = statusTemplateSource.copy() as? NSImage else {
                fatalError("Unable to copy bundled brand resource OmniWMStatusTemplate.pdf")
            }
            image.size = NSSize(width: pointSize, height: pointSize)
            image.isTemplate = true
            statusTemplates[pointSize] = image
            template = image
        }
        guard let image = template.copy() as? NSImage else {
            fatalError("Unable to copy bundled brand resource OmniWMStatusTemplate.pdf")
        }
        image.isTemplate = true
        return image
    }

    static func secureInputStatusImage(pointSize: CGFloat, tint: NSColor) -> NSImage {
        lockedImage(template: statusItemImage(pointSize: pointSize), tint: tint)
    }

    private nonisolated static func lockedImage(template: NSImage, tint: NSColor) -> NSImage {
        let image = NSImage(size: template.size, flipped: false) { rect in
            template.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            let unit = rect.width / 24
            let body = NSBezierPath(
                roundedRect: NSRect(x: 14.2 * unit, y: 1.4 * unit, width: 8.8 * unit, height: 7.4 * unit),
                xRadius: 1.4 * unit,
                yRadius: 1.4 * unit
            )
            let shackle = NSBezierPath()
            shackle.move(to: NSPoint(x: 16.2 * unit, y: 8.6 * unit))
            shackle.appendArc(
                withCenter: NSPoint(x: 18.6 * unit, y: 10.6 * unit),
                radius: 2.4 * unit,
                startAngle: 180,
                endAngle: 0,
                clockwise: true
            )
            shackle.line(to: NSPoint(x: 21 * unit, y: 8.6 * unit))
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSColor.black.set()
            body.lineWidth = 1.4 * unit
            body.fill()
            body.stroke()
            shackle.lineWidth = 3.6 * unit
            shackle.stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.systemRed.set()
            body.fill()
            shackle.lineWidth = 1.7 * unit
            shackle.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    static var launchLockupImage: NSImage {
        guard let image = launchLockup.copy() as? NSImage else {
            fatalError("Unable to copy bundled brand resource OmniWMLaunchLockup.pdf")
        }
        return image
    }

    static var launchLockupAspect: CGFloat {
        launchLockup.size.width / launchLockup.size.height
    }

    private static func resourceImage(named name: String, isTemplate: Bool) -> NSImage {
        guard let url = Bundle.module.url(forResource: name, withExtension: "pdf"),
              let image = NSImage(contentsOf: url),
              image.isValid,
              image.size.width > 0,
              image.size.height > 0
        else {
            fatalError("Missing bundled brand resource \(name).pdf")
        }
        image.isTemplate = isTemplate
        return image
    }
}
