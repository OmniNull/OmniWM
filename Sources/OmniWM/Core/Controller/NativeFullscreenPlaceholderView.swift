// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import CoreText

final class NativeFullscreenPlaceholderView: NSView {
    private static let status = String(localized: "In macOS Full Screen")
    private static let subtitle = String(localized: "Move or resize this slot; the window will return here.")
    private static let activationModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift, .function]
    private static let titleFont = NSFont.systemFont(ofSize: 17, weight: .semibold) as CTFont
    private static let subtitleFont = NSFont.systemFont(ofSize: 12) as CTFont

    private let appName: String
    private let icon: CGImage?
    private var titleLine: CTLine
    private static let statusLine = makeLine(status, font: subtitleFont, color: .white)
    private static let subtitleLine = makeLine(
        subtitle,
        font: subtitleFont,
        color: NSColor.white.withAlphaComponent(0.78)
    )
    private static let titleEllipsis = makeLine("…", font: titleFont, color: .white)
    private static let subtitleEllipsis = makeLine(
        "…",
        font: subtitleFont,
        color: NSColor.white.withAlphaComponent(0.78)
    )
    private(set) var titleText: String
    private(set) var displayedTitleLine: CTLine?
    private(set) var displayedStatusLine: CTLine?
    private var displayedSubtitleLine: CTLine?
    private var textWidth: CGFloat = -1
    private var tracking: NSTrackingArea?
    private var isHovered = false
    private var isPressed = false
    private var isTrackingPrimaryPress = false
    private var isSelected = false

    var onActivate: (() -> Void)?

    init(windowTitle: String, appName: String?, icon: NSImage?) {
        let resolvedAppName = appName.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Application")
        self.appName = resolvedAppName
        titleText = Self.resolvedTitle(windowTitle, appName: resolvedAppName)
        titleLine = Self.makeLine(titleText, font: Self.titleFont, color: .white)
        let sourceIcon = icon ?? NSImage(named: NSImage.applicationIconName)
        self.icon = sourceIcon?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        toolTip = String(localized: "Press to switch Spaces. The tiling position remains reserved.")
        updateTextGeometry()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTextGeometry()
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        updateTextGeometry()
    }

    func setWindowTitle(_ windowTitle: String) {
        let nextTitle = Self.resolvedTitle(windowTitle, appName: appName)
        guard titleText != nextTitle else { return }
        titleText = nextTitle
        titleLine = Self.makeLine(nextTitle, font: Self.titleFont, color: .white)
        textWidth = -1
        updateTextGeometry()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        if let tracking {
            removeTrackingArea(tracking)
        }
        let nextTracking = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(nextTracking)
        tracking = nextTracking
        super.updateTrackingAreas()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let panelBounds = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = CGPath(
            roundedRect: panelBounds,
            cornerWidth: 10,
            cornerHeight: 10,
            transform: nil
        )

        context.addPath(path)
        context.setFillColor(resolvedColor(.black, alpha: 0.98))
        context.fillPath()

        if isHovered || isPressed {
            context.addPath(path)
            let alpha: CGFloat = isPressed ? 0.16 : 0.07
            context.setFillColor(resolvedColor(.controlAccentColor, alpha: alpha))
            context.fillPath()
        }

        context.addPath(path)
        context.setLineWidth(isSelected ? 2 : 1)
        context.setStrokeColor(
            isSelected
                ? resolvedColor(.controlAccentColor, alpha: 1)
                : resolvedColor(.separatorColor, alpha: 0.9)
        )
        context.strokePath()

        drawContent(in: context)
    }

    override func mouseEntered(with _: NSEvent) {
        setHovered(true)
    }

    override func mouseExited(with _: NSEvent) {
        setHovered(false)
        if isTrackingPrimaryPress {
            setPressed(false)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0,
              event.modifierFlags.isDisjoint(with: Self.activationModifiers)
        else { return }
        isTrackingPrimaryPress = true
        setPressed(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isTrackingPrimaryPress else { return }
        let point = convert(event.locationInWindow, from: nil)
        setPressed(
            bounds.contains(point)
                && event.modifierFlags.isDisjoint(with: Self.activationModifiers)
        )
    }

    override func mouseUp(with event: NSEvent) {
        guard isTrackingPrimaryPress else { return }
        let point = convert(event.locationInWindow, from: nil)
        let shouldActivate = event.buttonNumber == 0
            && bounds.contains(point)
            && event.modifierFlags.isDisjoint(with: Self.activationModifiers)
        isTrackingPrimaryPress = false
        setPressed(false)
        if shouldActivate {
            onActivate?()
        }
    }

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .button
    }

    override func accessibilityChildren() -> [Any]? {
        []
    }

    override func accessibilityLabel() -> String? {
        String(localized: "\(titleText), in macOS Full Screen")
    }

    override func accessibilityHelp() -> String? {
        String(localized: "Press to switch to the app's macOS Full Screen Space. Its tiling position remains reserved.")
    }

    override func accessibilityValue() -> Any? {
        NSNumber(value: isSelected)
    }

    override func accessibilityPerformPress() -> Bool {
        onActivate?()
        return true
    }

    func setSelected(_ selected: Bool) {
        guard isSelected != selected else { return }
        isSelected = selected
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    func cancelInteraction() {
        isTrackingPrimaryPress = false
        setPressed(false)
        setHovered(false)
    }

    private func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        needsDisplay = true
    }

    private func setPressed(_ pressed: Bool) {
        guard isPressed != pressed else { return }
        isPressed = pressed
        needsDisplay = true
    }

    private func drawContent(in context: CGContext) {
        let shortestSide = min(bounds.width, bounds.height)
        if bounds.width < 180 || bounds.height < 140 {
            let iconSide = min(64, max(min(shortestSide, 24), shortestSide - 24))
            drawIcon(
                in: CGRect(
                    x: (bounds.width - iconSide) / 2,
                    y: (bounds.height - iconSide) / 2,
                    width: iconSide,
                    height: iconSide
                ),
                context: context
            )
            return
        }
        let iconSide = min(96, max(48, shortestSide * 0.2))
        let titleHeight = CGFloat(CTFontGetAscent(Self.titleFont) + CTFontGetDescent(Self.titleFont))
        let subtitleHeight = CGFloat(CTFontGetAscent(Self.subtitleFont) + CTFontGetDescent(Self.subtitleFont))
        let contentHeight = iconSide + 16 + titleHeight + 12 + subtitleHeight * 2
        let contentBottom = max((bounds.height - contentHeight) / 2, 4)
        let iconFrame = CGRect(
            x: (bounds.width - iconSide) / 2,
            y: contentBottom + titleHeight + subtitleHeight * 2 + 28,
            width: iconSide,
            height: iconSide
        )
        drawIcon(in: iconFrame, context: context)
        drawCentered(
            line: displayedTitleLine,
            baseline: contentBottom + subtitleHeight * 2 + 12,
            context: context
        )
        drawCentered(
            line: displayedStatusLine,
            baseline: contentBottom + subtitleHeight + 6,
            context: context
        )
        drawCentered(
            line: displayedSubtitleLine,
            baseline: contentBottom,
            context: context
        )
    }

    private func drawIcon(in frame: CGRect, context: CGContext) {
        guard let icon else { return }
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(icon, in: frame)
        context.restoreGState()
    }

    private func drawCentered(
        line: CTLine?,
        baseline: CGFloat,
        context: CGContext
    ) {
        guard let line else { return }
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: (bounds.width - lineWidth) / 2, y: baseline)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func resolvedColor(_ color: NSColor, alpha: CGFloat) -> CGColor {
        var resolved: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = color.withAlphaComponent(alpha).cgColor
        }
        return resolved ?? color.withAlphaComponent(alpha).cgColor
    }

    private func updateTextGeometry() {
        let nextWidth = max(0, bounds.width - 48)
        guard textWidth != nextWidth else { return }
        textWidth = nextWidth
        displayedTitleLine = Self.truncatedLine(titleLine, width: nextWidth, token: Self.titleEllipsis)
        displayedStatusLine = Self.truncatedLine(Self.statusLine, width: nextWidth, token: Self.subtitleEllipsis)
        displayedSubtitleLine = Self.truncatedLine(Self.subtitleLine, width: nextWidth, token: Self.subtitleEllipsis)
        needsDisplay = true
    }

    private static func resolvedTitle(_ title: String, appName: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? appName : trimmed
    }

    private static func truncatedLine(_ line: CTLine, width: CGFloat, token: CTLine) -> CTLine? {
        guard width > 0 else { return nil }
        guard CTLineGetTypographicBounds(line, nil, nil, nil) > width else { return line }
        return CTLineCreateTruncatedLine(line, width, .end, token)
    }

    private static func makeLine(
        _ text: String,
        font: CTFont,
        color: NSColor
    ) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color
            ]
        ))
    }
}
