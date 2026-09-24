// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import IOSurface
import QuartzCore

@MainActor
final class OverviewWindowLayer {
    private typealias Colors = OverviewRenderStyle.Colors
    private typealias Metrics = OverviewRenderStyle.Metrics

    let root = CALayer()
    let thumbnail = CALayer()
    private let thumbnailClip = CALayer()
    private let dimming = CALayer()
    let border = CALayer()
    private var focusEffects: BorderEffectLayers?
    private struct FocusEffectKey: Equatable {
        let config: BorderConfig
        let bounds: CGRect
        let contentsScale: CGFloat
    }

    private var focusEffectKey: FocusEffectKey?
    private var contentsScale: CGFloat = 1
    private let info = CAGradientLayer()
    private let icon = CALayer()
    private let title = OverviewRenderer.textLayer(size: 12, color: Colors.textWhite)
    private let appName = OverviewRenderer.textLayer(size: 10, color: Colors.textGray)
    private let closeButton = CALayer()
    private let closeMark = CAShapeLayer()
    private(set) var preview: OverviewPreviewFrame?
    private var previewContentSize = CGSize.zero
    private var activeTransition: OverviewNativeTransition?
    private var emphasizedFullscreenCaption = ""
    private static let fullScreenCaption = String(localized: "Full Screen")

    init() {
        root.backgroundColor = Colors.windowBackground
        root.cornerRadius = Metrics.windowCornerRadius
        root.addSublayer(thumbnailClip)
        thumbnailClip.cornerRadius = Metrics.windowCornerRadius - 1
        thumbnailClip.masksToBounds = true
        thumbnailClip.addSublayer(thumbnail)
        thumbnail.contentsGravity = .resize
        root.addSublayer(dimming)
        dimming.backgroundColor = Colors.windowDimmed
        dimming.cornerRadius = Metrics.windowCornerRadius
        root.addSublayer(info)
        info.colors = [CGColor(gray: 0, alpha: 0.64), CGColor(gray: 0, alpha: 0.32), CGColor(gray: 0, alpha: 0)]
        info.locations = [0, 0.5, 1]
        info.startPoint = CGPoint(x: 0.5, y: 0)
        info.endPoint = CGPoint(x: 0.5, y: 1)
        info.cornerRadius = Metrics.windowCornerRadius
        info.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        info.masksToBounds = true
        for layer in [icon, title, appName] { info.addSublayer(layer) }
        root.addSublayer(border)
        border.cornerRadius = Metrics.windowCornerRadius
        root.addSublayer(closeButton)
        closeButton.cornerRadius = Metrics.closeButtonSize / 2
        closeButton.addSublayer(closeMark)
        closeMark.strokeColor = Colors.closeButtonX
        closeMark.lineWidth = 2
        closeMark.lineCap = .round
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 6, y: 6))
        path.addLine(to: CGPoint(x: 14, y: 14))
        path.move(to: CGPoint(x: 14, y: 6))
        path.addLine(to: CGPoint(x: 6, y: 14))
        closeMark.path = path
    }

    func updateContent(_ window: OverviewWindowItem, contentsScale: CGFloat) {
        self.contentsScale = contentsScale
        if title.string as? String != window.title { title.string = window.title }
        let caption = window.isNativeFullscreen ? Self.fullScreenCaption : window.appName
        if appName.string as? String != caption { appName.string = caption }
        if window.isNativeFullscreen {
            emphasizedFullscreenCaption = String(localized: "\(window.appName) · Full Screen")
        }
        if (icon.contents as AnyObject?) !== window.appIcon { icon.contents = window.appIcon }
        let fontSize = min(13, max(10, window.overviewFrame.height * 0.055))
        if title.fontSize != fontSize {
            title.font = NSFont.systemFont(ofSize: fontSize)
            title.fontSize = fontSize
        }
        for layer in [title, appName] { layer.contentsScale = contentsScale }
    }

    func updateGeometry(
        _ window: OverviewWindowItem,
        frame: CGRect,
        state: OverviewRenderState,
        transition: OverviewNativeTransition? = nil,
        replacing: Bool = false,
        time: CFTimeInterval = CACurrentMediaTime(),
        anchored: Bool = false
    ) {
        let motion = transition.map { _ in motionLayers.map { OverviewLayerMotion($0) } } ?? []
        activeTransition = transition
        root.frame = frame
        let coverage = anchored && preview != nil ? 1 : state.progress
        root.opacity = Float(coverage * (window.matchesSearch ? 1 : 0.3))
        thumbnailClip.frame = root.bounds.insetBy(dx: Metrics.thumbnailInset, dy: Metrics.thumbnailInset)
        updateThumbnailGeometry()
        dimming.frame = root.bounds
        dimming.isHidden = window.matchesSearch
        closeButton.frame = CGRect(
            x: root.bounds.maxX - Metrics.closeButtonSize - Metrics.closeButtonPadding,
            y: root.bounds.maxY - Metrics.closeButtonSize - Metrics.closeButtonPadding,
            width: Metrics.closeButtonSize,
            height: Metrics.closeButtonSize
        )
        updateEmphasis(window, state: state)
        if let transition {
            for snapshot in motion { snapshot.apply(transition, at: time, replacing: replacing) }
        }
    }

    func updateEmphasis(_ window: OverviewWindowItem, state: OverviewRenderState) {
        let selected = window.handle == state.selectedWindowHandle
        let hovered = window.handle == state.hoveredWindowHandle
        updateCaption(window, emphasized: selected || hovered)
        border.borderColor = OverviewRenderer.borderColor(
            isSelected: selected,
            isHovered: hovered,
            palette: state.palette
        )
        if selected, var config = state.palette.focusBorder {
            config.width *= window.contentScale
            if config.glow != nil { config.glow?.radius *= window.contentScale }
            let geometry = config.resolvedGeometry(for: root.bounds, scale: contentsScale)
            border.frame = geometry.targetFrame.insetBy(dx: -geometry.width, dy: -geometry.width)
            border.borderWidth = geometry.width
            border.cornerRadius = Metrics.windowCornerRadius + geometry.width
            let hasEffects = config.enabled && (config.gradient?.enabled == true || config.glow?.enabled == true)
            if hasEffects {
                if focusEffects == nil {
                    let effects = BorderEffectLayers()
                    root.insertSublayer(effects.root, below: border)
                    focusEffects = effects
                }
                let key = FocusEffectKey(config: config, bounds: root.bounds, contentsScale: contentsScale)
                if focusEffectKey != key {
                    focusEffectKey = key
                    focusEffects?.root.frame = geometry.surfaceFrame
                    focusEffects?.updateEffects(
                        geometry: geometry.localized(),
                        cornerRadii: WindowCornerRadii(uniform: Metrics.windowCornerRadius),
                        config: config,
                        baseColor: state.palette.selectedBorder,
                        scale: contentsScale
                    )
                }
            }
            focusEffects?.root.isHidden = !hasEffects
            if config.enabled, config.gradient?.enabled == true {
                border.borderColor = CGColor(gray: 0, alpha: 0)
            }
        } else {
            border.frame = root.bounds
            border.borderWidth = selected ? Metrics.selectedBorderWidth : Metrics.windowBorderWidth
            border.cornerRadius = Metrics.windowCornerRadius
            focusEffects?.root.isHidden = true
        }
        closeButton.isHidden = !hovered
        closeButton.backgroundColor = hovered && state.closeButtonHovered ? Colors.closeButtonHover : Colors
            .closeButtonBackground
    }

    func updatePreview(_ frame: OverviewPreviewFrame?, animated: Bool = false) {
        if frame == nil || !animated { finishPreviewReveal() }
        guard preview !== frame else { return }
        let previous = preview
        let motion = activeTransition.map { _ in OverviewLayerMotion(thumbnail) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { withExtendedLifetime(previous) {} }
        preview = frame
        thumbnail.contents = frame?.surface
        thumbnail.contentsRect = frame?.contentsRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        if let frame {
            previewContentSize = CGSize(
                width: CGFloat(frame.surface.width) * frame.contentsRect.width,
                height: CGFloat(frame.surface.height) * frame.contentsRect.height
            )
        } else {
            previewContentSize = .zero
        }
        updateThumbnailGeometry()
        if let activeTransition { motion?.apply(activeTransition, at: CACurrentMediaTime(), replacing: false) }
        if previous == nil, frame != nil, animated {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 0
            animation.toValue = 1
            animation.duration = 0.15
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            thumbnail.add(animation, forKey: "overview.previewReveal")
        }
        CATransaction.commit()
    }

    func finishPreviewReveal() {
        thumbnail.removeAnimation(forKey: "overview.previewReveal")
    }

    private var motionLayers: [CALayer] {
        var layers = [root, thumbnailClip, thumbnail, dimming, border, info, closeButton]
        if let focusEffects { layers.append(focusEffects.root) }
        return layers
    }

    func cancelAnimation() {
        activeTransition = nil
        for layer in motionLayers { OverviewLayerMotion.remove(from: layer) }
    }

    func hit(at point: CGPoint) -> Bool? {
        let frame = displayedFrame
        let bounds = OverviewLayerMotion.displayedBounds(of: root)
        guard !root.isHidden, OverviewLayerMotion.displayedOpacity(of: root) > 0,
              frame.contains(point) else { return nil }
        let local = CGPoint(
            x: point.x - frame.minX + bounds.minX,
            y: point.y - frame.minY + bounds.minY
        )
        return OverviewLayerMotion.displayedFrame(of: closeButton).contains(local)
    }

    var displayedFrame: CGRect {
        OverviewLayerMotion.displayedFrame(of: root)
    }

    var isAnimating: Bool {
        root.animation(forKey: "overview.position") != nil
            || root.animation(forKey: "overview.bounds") != nil
            || root.animation(forKey: "overview.opacity") != nil
    }

    private func updateThumbnailGeometry() {
        thumbnail.frame = OverviewRenderGeometry.aspectFitRect(
            contentSize: previewContentSize,
            in: thumbnailClip.bounds
        )
    }

    private func updateCaption(_ window: OverviewWindowItem, emphasized: Bool) {
        appName.isHidden = !emphasized && !window.isNativeFullscreen
        let caption = if window.isNativeFullscreen {
            emphasized ? emphasizedFullscreenCaption : Self.fullScreenCaption
        } else {
            window.appName
        }
        if appName.string as? String != caption { appName.string = caption }
        let iconSize = min(24, max(14, window.overviewFrame.height * 0.16))
        let titleHeight = ceil(title.fontSize + 4)
        let textHeight = titleHeight + (appName.isHidden ? 0 : 14)
        let contentHeight = max(iconSize, textHeight)
        info.frame = CGRect(x: 0, y: 0, width: root.bounds.width, height: min(root.bounds.height, contentHeight + 20))
        icon.frame = CGRect(x: 8, y: 6 + (contentHeight - iconSize) / 2, width: iconSize, height: iconSize)
        let textX = icon.frame.maxX + 6
        let textWidth = max(0, root.bounds.width - textX - 8)
        let textY = 6 + (contentHeight - textHeight) / 2
        title.frame = CGRect(x: textX, y: textY + (appName.isHidden ? 0 : 14), width: textWidth, height: titleHeight)
        appName.frame = CGRect(x: textX, y: textY, width: textWidth, height: 14)
    }
}
