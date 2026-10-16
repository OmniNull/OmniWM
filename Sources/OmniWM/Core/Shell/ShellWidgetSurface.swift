// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
import OmniWMScriptHost
import OmniWMShellCore
import QuartzCore

@MainActor
final class ShellWidgetSurface {
    let sourceID = ShellInvocation.next()
    let view: ShellSurfaceView
    let scale: CGFloat
    var onAction: (@MainActor (ShellClick) -> Void)?
    var onShapeChange: (@MainActor () -> Void)?
    var onLayoutMenu: (@MainActor (ShellAnchor) -> Void)?
    var onMenu: (@MainActor (ShellMenuEvent) -> Void)?
    var onPreview: (@MainActor (ShellPreviewEvent) -> Void)?
    var onDrag: (@MainActor (ShellDragEvent) -> Void)?
    var onTooltip: (@MainActor (ShellTooltipEvent?) -> Void)?
    var onMove: (@MainActor () -> Void)?
    var onFocusChange: (@MainActor (Bool) -> Void)?
    var sequence = 0
    var resourceImages: [Int32: ResourceImageBinding] = [:]
    var resourceDragBridge: ShellDragOutBridge? {
        didSet { resourceDragTracker?.cancel()
            resourceDragTracker = nil
        }
    }

    var resourceDragTracker: ShellDragOutTracker?
    var resourceDropBridge: ShellDropBridge? {
        didSet { cancelResourceDrop()
            dropPreflight = nil
            onResourceDropInvalidated?()
        }
    }

    var onResourceDrop: (@MainActor (
        ShellDropReservation,
        ShellDropSnapshot,
        CGPoint,
        @escaping @Sendable (ShellDropReservation) -> Void
    ) -> Void)?
    var onResourceDropInvalidated: (@MainActor () -> Void)?
    var onResourceDropDeclined: (@MainActor (String) -> Void)?
    var dropPreflight: ShellDropPreflight?
    var hasResourceDrops = false
    var onResourceDropRegistrationChange: (() -> Void)?
    var onResourceDragEnd: (() -> Void)?
    var dropTarget: ShellPointerCapture?
    var dropPoint: CGPoint?
    var dropOffered: ShellDropTypes = []
    var dropHoverTypes: ShellDropTypes = []
    var dropCanCopy = false
    var dropPasteboardChange: Int?
    var dropSequence: Int?
    let layout = ShellWidgetLayout()
    let scene: ShellLayerScene
    let resources: ShellResources
    let palette: ShellPalette
    let motionPolicy: MotionPolicy
    var animates = false
    var drawsRootMaterial = false
    var symbolImages: [SymbolKey: CGImage] = [:]
    var iconImages: [IconKey: CGImage] = [:]
    var pointer: CGPoint?
    var hovered: [ElementHandle] = []
    var hoverScratch: [ElementHandle] = []
    var focused = ElementHandle.none
    var ringed = ElementHandle.none
    var focusAxis: ShellFocusAxis?
    var declaredFocus = false
    var keyDeclaration: UInt32 = 0
    var declaredKeys: Set<String> = []
    var tooltipTarget = ElementHandle.none
    var tooltipTimer: DispatchWorkItem?
    var previewed = ElementHandle.none
    var previewFrame: Rect?
    var pressed = ElementHandle.none
    var pressedButton = ShellEvent.Button.left
    var pressCapture: ShellPointerCapture?
    var pressInside = false
    var hasHoverHandlers = false
    var outsidePressTargets: [ElementHandle] = []
    var hoverIntent: ShellPointerCapture?
    var hoverPoint = CGPoint.zero
    var hoverActive = false
    var hoverEnding = false
    var hoverTimer: DispatchWorkItem?
    var pointerGesture: ShellPointerGesture?
    var gestureCapture: ShellPointerCapture?
    var presenceRecipes: [UInt32: ShellPresenceRecipe] = [:]
    var gestureTrackRecipes: [UInt32: ShellGestureTrackRecipe] = [:]
    var gestureTracking: ShellTrackedGesture?
    var gesturePosition = CGPoint.zero
    var gesturePointer = CGPoint.zero
    var sliding = ElementHandle.none
    var dragStart: (handle: ElementHandle, point: CGPoint)?
    var dragging = false
    var textInputs: [ElementHandle: ShellTextInput] = [:]
    weak var text: ShellTextStore?

    struct SymbolKey: Hashable {
        let name: String
        let color: Color
        let style: UInt32
    }

    struct IconKey: Hashable {
        let source: IconSource
        let reference: String
        let pixels: Int
        let tint: Color
    }

    struct ShaderBinding {
        let handle: ElementHandle
        let source: String
        var program: ShellShaderProgram
        var assetURL: URL?
        var textureURL: URL?
    }

    struct AssetImageBinding {
        let handle: ElementHandle
        let source: String
        var url: URL?
        var frames: ShellImageFrames?
    }

    let directories: [URL]
    let shaderDirectories: [URL]
    var shaders: [Int32: ShaderBinding] = [:]
    var assetImages: [Int32: AssetImageBinding] = [:]
    var assetFolders: [String: URL] = [:] {
        didSet {
            if assetFolders != oldValue { refreshAssets() }
        }
    }

    var paths: [Int32: ShellLayerPath] = [:]
    var pathCache: [String: ShellPathData?] = [:]
    static let pathCacheLimit = 64
    var maskOwners: [Int32: ElementHandle] = [:]
    var fittedPaths: [Int32: (size: CGSize, path: CGPath)] = [:]
    var samples: [Int32: (point: CGPoint, inside: Bool)] = [:]
    var sampling: Set<Int32> = []
    var wantedSamples: [Int32: CGPoint] = [:]
    static let alphaThreshold: Float = 0.1
    private(set) var visible = true
    private(set) var transition = ShellShaderTransition.settled

    init(scale: CGFloat, resources: ShellResources, directories: [URL]) {
        self.resources = resources
        self.directories = directories
        shaderDirectories = directories.prefix(1) + directories.dropFirst().map {
            $0.appendingPathComponent("shaders", isDirectory: true)
        }
        palette = resources.palette
        motionPolicy = resources.motion
        let container = CALayer()
        container.anchorPoint = .zero
        container.contentsScale = scale
        view = ShellSurfaceView(container: container)
        scene = ShellLayerScene(container: container, scale: scale)
        self.scale = scale
        view.surface = self
    }

    isolated deinit {
        onResourceDropInvalidated?()
        dropPreflight?.clear()
        for entry in resourceImages.values {
            if let binding = entry.binding { resources.resourceImages?.release(binding) }
        }
    }
}

extension ShellWidgetSurface {
    var size: CGSize {
        layout.size
    }

    var naturalSize: CGSize {
        layout.naturalSize
    }

    var chrome: ShellPopoutChrome {
        let root = layout.core.rootHandle
        guard layout.core.contains(root) else { return ShellPopoutChrome() }
        let paint = layout.core.paint(of: root)
        return ShellPopoutChrome(
            glass: paint.material == OMNI_MATERIAL_GLASS,
            clear: paint.material == OMNI_MATERIAL_CLEAR,
            radius: paint.cornerRadius > 0 ? CGFloat(paint.cornerRadius) : ShellPopoutChrome().radius
        )
    }

    @discardableResult
    func apply(_ output: [UInt8], text: ShellTextStore, gestureAcknowledgement: UInt64 = 0) -> Bool {
        guard layout.apply(output, text: text) else {
            acknowledgeGesture(through: gestureAcknowledgement)
            return false
        }
        if self.text !== text { keyDeclaration = 0
            declaredKeys = []
        }
        self.text = text
        updateInputDeclarations()
        reconcileInput()
        updateDeclaredKeys()
        ShellFrameTraceDisplayLink.prepare(screen: view.window?.screen)
        updatePreview()
        if focusAxis != nil, !layout.core.contains(focused) {
            focused = focusLines().items.first ?? .none
        }
        var commands = commands(text: text)
        reconcileResourceDrop()
        updateHover(into: &commands, reapply: true)
        appendGestureAcknowledgement(gestureAcknowledgement, into: &commands)
        scene.submit(commands, animated: animates && motionPolicy.animationsEnabled)
        animates = true
        onMove?()
        return true
    }

    var failedShader: ShellShaderProgram? {
        shaders.values.lazy.map(\.program).first { $0.failure != nil }
    }

    func refreshShaders(includingAssets: Bool = true) {
        guard !shaders.isEmpty else { return }
        var commands: [ShellLayerCommand] = []
        for (slot, binding) in shaders where layout.core.contains(binding.handle)
            && (includingAssets || !binding.source.hasPrefix(ShellAsset.prefix))
        {
            let program = resources.shaders.program(
                source: binding.source,
                directories: shaderDirectories,
                packages: assetFolders
            )
            shaders[slot]?.program = program
            shaders[slot]?.assetURL = assetURL(binding.source)
            commands.append(.shader(
                slot: slot,
                program: program,
                input: shaderInput(layout.core.content(of: binding.handle))
            ))
        }
        scene.submit(commands, animated: false)
    }

    var bridges: Bool {
        rootContent?.bridges == true
    }

    var attaches: Bool {
        rootContent?.attaches == true
    }

    private var rootContent: Content? {
        let root = layout.core.rootHandle
        return layout.core.contains(root) ? layout.core.content(of: root) : nil
    }

    var timing: ShellTiming {
        let root = layout.core.rootHandle
        guard layout.core.contains(root) else { return ShellTiming() }
        let content = layout.core.content(of: root)
        return ShellTiming(open: content.openDuration, close: content.closeDuration)
    }

    func setStage(_ stage: ShellShaderStage?) {
        scene.submit([.stage(stage)], animated: false)
    }

    func setRootBleed(_ bleed: Insets) {
        guard bleed != layout.core.rootBleed, let text else { return }
        layout.setRootBleed(bleed)
        scene.submit(commands(text: text), animated: false)
    }

    func setRootLimit(_ limit: CGSize?) {
        let size = limit.map { Size2(width: Float($0.width), height: Float($0.height)) }
            ?? Size2(width: .infinity, height: .infinity)
        guard size != layout.core.rootLimit else { return }
        layout.setRootLimit(size)
        guard let text else { return }
        scene.submit(commands(text: text), animated: false)
    }

    var animatesShaders: Bool {
        shaders.values.contains { binding in
            layout.core.contains(binding.handle) && shaderInput(layout.core.content(of: binding.handle)).rate > 0
        }
    }

    func setTransition(_ next: ShellShaderTransition) {
        guard transition != next else { return }
        transition = next
        scene.submit([.transition(next)], animated: false)
    }

    func setVisible(_ isVisible: Bool) {
        guard visible != isVisible else { return }
        visible = isVisible
        if !isVisible {
            onResourceDropInvalidated?()
            cancelResourceDrop()
            pointer = nil
            cancelInput()
            let hadDeclaredFocus = declaredFocus
            blurDeclaredFocus()
            if !hadDeclaredFocus { onFocusChange?(false) }
        }
        scene.submit([.visibility(isVisible)], animated: false)
        if isVisible { realizeTextInputFocus() }
    }

    func reset(text: ShellTextStore) {
        onResourceDropInvalidated?()
        cancelResourceDrop()
        updateResourceDropRegistration(false)
        clearResourceImages()
        cancelInput()
        blurDeclaredFocus()
        for input in textInputs.values { input.remove() }
        textInputs.removeAll(keepingCapacity: true)
        self.text = text
        layout.reset()
        hasHoverHandlers = false
        gestureTrackRecipes.removeAll(keepingCapacity: true)
        presenceRecipes.removeAll(keepingCapacity: true)
        outsidePressTargets.removeAll(keepingCapacity: true)
        shaders.removeAll()
        assetImages.removeAll()
        previewFrame = nil
        if previewed.slot >= 0 {
            previewed = .none
            onPreview?(ShellPreviewEvent(target: 0, anchor: nil))
        }
        symbolImages.removeAll()
        iconImages.removeAll()
        hovered = []
        focused = .none
        ringed = .none
        hideTooltip()
        pressed = .none
        animates = false
        scene.submit([.clearExits] + commands(text: text), animated: false)
        onMove?()
    }
}

extension CGRect {
    init(_ rect: Rect) {
        self.init(x: CGFloat(rect.x), y: CGFloat(rect.y), width: CGFloat(rect.width), height: CGFloat(rect.height))
    }
}

extension Color {
    var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }
}
