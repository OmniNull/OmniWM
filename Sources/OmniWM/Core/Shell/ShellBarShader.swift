// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import TOML

struct ShellBarShader: Equatable {
    var source: String
    var fps = 30
    var values = SIMD4<Float>.zero

    static func parse(_ node: TOMLNode?, problems: inout [String]) -> Self? {
        guard let node else { return nil }
        guard case let .table(table) = node else {
            ShellConfig.report("shell.toml: [barShader] must be a table", &problems)
            return nil
        }
        for key in table.keys.sorted() where !["enabled", "source", "fps", "values"].contains(key) {
            ShellConfig.report("shell.toml: [barShader] has unknown key \(key)", &problems)
        }
        if let enabled = table["enabled"] {
            guard case let .boolean(value) = enabled else {
                ShellConfig.report("shell.toml: [barShader] enabled must be a boolean", &problems)
                return nil
            }
            if !value { return nil }
        }
        guard case let .string(source)? = table["source"], !source.isEmpty,
              !source.hasPrefix("."), !source.contains("/"), source.hasSuffix(".metal")
        else {
            ShellConfig.report("shell.toml: [barShader] source must be a shader filename ending in .metal", &problems)
            return nil
        }
        guard let fps = frameRate(table["fps"]) else {
            ShellConfig.report("shell.toml: [barShader] fps must be an integer between 0 and 60", &problems)
            return nil
        }
        var shader = Self(source: source, fps: fps)
        if let node = table["values"] {
            guard let values = parameters(node) else {
                ShellConfig.report("shell.toml: [barShader] values must contain up to four finite numbers", &problems)
                return nil
            }
            shader.values = values
        }
        return shader
    }

    private static func frameRate(_ node: TOMLNode?) -> Int? {
        guard let node else { return 30 }
        guard let value = ShellConfig.number(node), value.isFinite,
              (0 ... 60).contains(value), value.rounded() == value else { return nil }
        return Int(value)
    }

    private static func parameters(_ node: TOMLNode) -> SIMD4<Float>? {
        guard case let .array(nodes) = node, nodes.count <= 4 else { return nil }
        var values = SIMD4<Float>.zero
        for (index, node) in nodes.enumerated() {
            guard let value = ShellConfig.number(node), value.isFinite, Float(value).isFinite else { return nil }
            values[index] = Float(value)
        }
        return values
    }
}

@MainActor
final class ShellBarShaderView: NSView {
    private(set) var scene: ShellLayerScene?
    private(set) var renderScale: CGFloat = 0
    private(set) var visible = false
    private var renderedSize = CGSize.zero
    private var program: ShellShaderProgram?
    private var input: ShellShaderInput?
    private var paused = false

    override var isFlipped: Bool {
        true
    }

    init() {
        super.init(frame: .zero)
        let container = CALayer()
        container.isGeometryFlipped = true
        layer = container
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(program: ShellShaderProgram, input: ShellShaderInput, paused: Bool) {
        self.program = program
        self.input = input
        self.paused = paused
        refreshVisibility()
        updateGeometry()
        scene?.submit([.shader(slot: 0, program: program, input: input)], animated: false)
    }

    func setPaused(_ paused: Bool) {
        self.paused = paused
        refreshVisibility()
    }

    func stop() {
        program = nil
        input = nil
        visible = false
        scene?.submit([.visibility(false), .remove(slot: 0)], animated: false)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGeometry()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateGeometry()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let window {
            center.addObserver(
                self, selector: #selector(refreshVisibility),
                name: NSWindow.didChangeOcclusionStateNotification, object: window
            )
        }
        refreshVisibility()
        updateGeometry()
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    @objc private func refreshVisibility() {
        let next = !paused && program != nil && window?.occlusionState.contains(.visible) == true
        guard next != visible else { return }
        visible = next
        scene?.submit([.visibility(next)], animated: false)
    }

    static func scale(for size: CGSize, backingScale: CGFloat) -> CGFloat {
        let longest = max(size.width, size.height)
        guard longest.isFinite, longest > 0 else { return backingScale }
        return min(backingScale, CGFloat(ShellShaderDrawer.maximumPixels).nextDown / longest)
    }

    private func updateGeometry() {
        guard let layer, let program, let input, bounds.width > 0, bounds.height > 0 else { return }
        let scale = Self.scale(for: bounds.size, backingScale: window?.backingScaleFactor ?? 2)
        if scene == nil || scale != renderScale {
            scene?.submit([.visibility(false), .remove(slot: 0)], animated: false)
            scene?.container.removeFromSuperlayer()
            let container = CALayer()
            container.anchorPoint = .zero
            container.contentsScale = scale
            layer.addSublayer(container)
            let next = ShellLayerScene(container: container, scale: scale)
            scene = next
            renderScale = scale
            renderedSize = bounds.size
            next.submit([
                .visibility(visible),
                .insert(slot: 0, parent: -1, kind: .shader, after: -1),
                .frame(slot: 0, rect: CGRect(origin: .zero, size: bounds.size), animation: nil),
                .shader(slot: 0, program: program, input: input)
            ], animated: false)
        } else if renderedSize != bounds.size {
            renderedSize = bounds.size
            scene?.submit([
                .frame(slot: 0, rect: CGRect(origin: .zero, size: bounds.size), animation: nil)
            ], animated: false)
        }
    }
}
