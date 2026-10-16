// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
final class ShellPopoutPanel: ShellFocusPanel {
    private let effectView = NSVisualEffectView()
    private let glassView = NSGlassEffectView()
    private let content: NSView
    private var morphs = 0
    static let morphPosition = "morph.position"
    static let morphBounds = "morph.bounds"

    init(content: NSView) {
        self.content = content
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isFloatingPanel = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        animationBehavior = .none
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.masksToBounds = true
        glassView.style = .regular
        let container = NSView()
        for view in [effectView, glassView] {
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        }
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        container.addSubview(content)
        contentView = container
    }

    var showsGlass: Bool {
        !glassView.isHidden
    }

    func show(
        frame: CGRect,
        content contentFrame: CGRect? = nil,
        level: NSWindow.Level,
        chrome: ShellPopoutChrome,
        fadeDuration: TimeInterval?,
        from start: CGRect? = nil,
        morph: ShellAnimation? = nil
    ) {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        effectView.material = reduceTransparency ? .windowBackground : .popover
        effectView.blendingMode = reduceTransparency ? .withinWindow : .behindWindow
        effectView.isHidden = chrome.glass || chrome.clear
        glassView.isHidden = !chrome.glass
        hasShadow = !chrome.clear && contentFrame == nil
        effectView.layer?.cornerRadius = chrome.radius
        glassView.cornerRadius = chrome.radius
        content.layer?.cornerRadius = chrome.radius
        content.layer?.masksToBounds = contentFrame == nil
        self.level = level
        morphs += 1
        let inner = contentFrame ?? CGRect(origin: .zero, size: frame.size)
        if let morph, isVisible, self.frame != frame {
            let shown = content.layer?.presentation()?.frame ?? content.frame
            self.morph(from: (self.frame, shown), to: (frame, inner), animation: morph)
            return
        }
        setFrame(frame, display: true)
        for view in [effectView, glassView, content] {
            view.layer?.removeAnimation(forKey: Self.morphPosition)
            view.layer?.removeAnimation(forKey: Self.morphBounds)
            view.frame = inner
        }
        guard !isVisible else { return }
        orderIn(frame: frame, from: start, fadeDuration: fadeDuration)
    }

    private func orderIn(frame: CGRect, from start: CGRect?, fadeDuration: TimeInterval?) {
        OwnedWindowRegistry.shared.register(
            self,
            surfaceId: "shell-widget-popout-\(ObjectIdentifier(self))",
            policy: SurfacePolicy(
                kind: .workspaceBar,
                hitTestPolicy: .interactive,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: false
            )
        )
        if let fadeDuration {
            alphaValue = 0
            if let start {
                setFrame(start, display: false)
            }
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = fadeDuration
                animator().alphaValue = 1
                if start != nil {
                    animator().setFrame(frame, display: true)
                }
            }
        } else {
            alphaValue = 1
            orderFrontRegardless()
        }
    }

    private func morph(
        from previous: (frame: CGRect, inner: CGRect),
        to target: (frame: CGRect, inner: CGRect),
        animation: ShellAnimation
    ) {
        let union = previous.frame.union(target.frame)
        let start = previous.inner.offsetBy(dx: previous.frame.minX - union.minX, dy: previous.frame.minY - union.minY)
        let end = target.inner.offsetBy(dx: target.frame.minX - union.minX, dy: target.frame.minY - union.minY)
        let generation = morphs
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                self?.finishMorph(generation, at: target)
            }
        }
        setFrame(union, display: true)
        for view in [effectView, glassView, content] {
            view.frame = start
            guard let layer = view.layer else {
                view.frame = end
                continue
            }
            let from = (position: layer.position, bounds: layer.bounds)
            view.frame = end
            for (keyPath, value) in [
                ("position", NSValue(point: from.position)),
                ("bounds", NSValue(rect: from.bounds))
            ] {
                let move = animation.keyframes(keyPath, from: value, on: layer) ?? {
                    let basic = animation.make(keyPath)
                    basic.fromValue = value
                    return basic
                }()
                layer.add(move, forKey: keyPath == "position" ? Self.morphPosition : Self.morphBounds)
            }
        }
        CATransaction.commit()
    }

    private func finishMorph(_ generation: Int, at target: (frame: CGRect, inner: CGRect)) {
        guard generation == morphs else { return }
        setFrame(target.frame, display: true)
        for view in [effectView, glassView, content] {
            view.frame = target.inner
        }
    }

    func hide(
        fadeDuration: TimeInterval?,
        holdsUntilEnd: Bool = false,
        onHidden: @escaping @MainActor () -> Void = {}
    ) {
        guard isVisible else { return }
        OwnedWindowRegistry.shared.unregister(self)
        guard let fadeDuration else {
            orderOut(nil)
            return
        }
        ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeDuration
            if holdsUntilEnd {
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.9, 0, 1, 1)
            }
            animator().alphaValue = 0
        } completionHandler: { [self] in
            Task { @MainActor in
                orderOut(nil)
                onHidden()
            }
        }
    }
}
