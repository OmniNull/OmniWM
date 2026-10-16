// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
import OmniWMScriptHost
import OmniWMShellCore
import QuartzCore

extension ShellWidgetSurface {
    private static let sliderTrack = Color(
        red: 0,
        green: 0,
        blue: 0,
        alpha: 0,
        role: UInt16(ShellRole.foreground.rawValue + 1) | UInt16(51) << 8
    )

    func commands(text: ShellTextStore) -> [ShellLayerCommand] {
        var commands: [ShellLayerCommand] = []
        let count = layout.patches.count
        commands.reserveCapacity(count)
        for index in 0 ..< count {
            switch layout.patches.op(at: index) {
            case let .insert(handle, parent, kind, after):
                if kind == .input { insertTextInput(handle) }
                let key = layout.core.key(of: handle)
                commands.append(.insert(
                    slot: handle.slot, parent: parent.slot, kind: kind, after: after.slot,
                    identity: key == 0 ? nil : ShellLayerIdentity(parent: parent, key: key, kind: kind)
                ))
            case let .remove(handle):
                forget(handle)
                commands.append(.remove(slot: handle.slot))
            case let .move(handle, _, after):
                commands.append(.move(slot: handle.slot, after: after.slot))
            case let .setFrame(handle, rect):
                commands.append(.frame(slot: handle.slot, rect: CGRect(rect), animation: animation(for: handle)))
            case let .setPaint(handle, paint):
                trackMask(handle, masks: paint.masks)
                commands.append(paintCommand(handle, paint))
            case let .setText(handle, id, style, color, maxWidth, lines):
                if layout.core.kind(of: handle) == .input { continue }
                commands.append(textCommand(
                    handle,
                    text: text,
                    content: .init(id: id, style: style, color: color, maxWidth: maxWidth, lines: lines)
                ))
            case let .setScroll(handle, offset, vertical):
                commands.append(.scroll(slot: handle.slot, origin: Self.scrollOrigin(offset, vertical: vertical)))
            case let .setPath(handle):
                commands.append(pathCommand(handle, text: text))
            case let .setShader(handle):
                commands.append(shaderCommand(handle, text: text))
            case let .setValue(handle, value, color):
                commands.append(.value(
                    slot: handle.slot,
                    fraction: CGFloat(value) / 1000,
                    color: palette.color(color, default: .accent),
                    track: palette.color(Self.sliderTrack),
                    animation: animation(for: handle)
                ))
            }
        }
        if shaders.contains(where: { !layout.core.contains($0.value.handle) }) {
            shaders = shaders.filter { layout.core.contains($0.value.handle) }
        }
        updateTextInputs()
        return commands
    }

    private struct TextPatch {
        let id: UInt32
        let style: UInt32
        let color: Color
        let maxWidth: Float
        let lines: UInt8
    }

    private func textCommand(_ handle: ElementHandle, text: ShellTextStore, content: TextPatch) -> ShellLayerCommand {
        let string = text.string(content.id)
        return imageCommand(handle, string, color: content.color, style: content.style, text: text) ?? .text(
            slot: handle.slot,
            text: string,
            style: content.style,
            color: palette.color(content.color, default: .foreground),
            maxWidth: CGFloat(content.maxWidth),
            lines: Int(content.lines),
            animation: animation(for: handle)
        )
    }

    private func forget(_ handle: ElementHandle) {
        forgetResourceImage(handle)
        removeTextInput(handle)
        shaders.removeValue(forKey: handle.slot)
        assetImages.removeValue(forKey: handle.slot)
        paths.removeValue(forKey: handle.slot)
        forgetShape(handle)
    }

    private func pathCommand(_ handle: ElementHandle, text: ShellTextStore) -> ShellLayerCommand {
        let path = layerPath(layout.core.content(of: handle), text: text)
        paths[handle.slot] = path
        fittedPaths.removeValue(forKey: handle.slot)
        return .path(slot: handle.slot, path, animation: animation(for: handle))
    }

    private func shaderCommand(_ handle: ElementHandle, text: ShellTextStore) -> ShellLayerCommand {
        let content = layout.core.content(of: handle)
        let source = text.string(content.text)
        let program = shaders[handle.slot].flatMap { $0.source == source ? $0.program : nil }
            ?? resources.shaders.program(source: source, directories: shaderDirectories, packages: assetFolders)
        shaders[handle.slot] = ShaderBinding(
            handle: handle,
            source: source,
            program: program,
            assetURL: assetURL(source),
            textureURL: textureURL(content)
        )
        return .shader(slot: handle.slot, program: program, input: shaderInput(content))
    }

    private func textureURL(_ content: Content) -> URL? {
        guard content.textureRef != 0, let source = text?.string(content.textureRef) else { return nil }
        return assetURL(source) ?? ShellImageLibrary.resolve(source, in: directories)
    }

    func assetURL(_ source: String) -> URL? {
        try? ShellAsset(source, packages: assetFolders).url
    }

    func refreshAssets(at url: URL? = nil) {
        var commands: [ShellLayerCommand] = []
        for (slot, binding) in shaders where layout.core.contains(binding.handle)
            && (url == nil || binding.assetURL == url || binding.textureURL == url)
        {
            let content = layout.core.content(of: binding.handle)
            let nextURL = assetURL(binding.source)
            let textureURL = textureURL(content)
            guard url != nil || nextURL != binding.assetURL || textureURL != binding.textureURL else { continue }
            let program = resources.shaders.program(
                source: binding.source,
                directories: shaderDirectories,
                packages: assetFolders
            )
            shaders[slot]?.assetURL = nextURL
            shaders[slot]?.textureURL = textureURL
            guard !program.isCompiling || binding.program.pipeline == nil else { continue }
            shaders[slot]?.program = program
            commands.append(.shader(
                slot: slot,
                program: program,
                input: shaderInput(layout.core.content(of: binding.handle))
            ))
        }
        for (slot, binding) in assetImages where layout.core.contains(binding.handle)
            && (url == nil || binding.url == url)
        {
            let nextURL = assetURL(binding.source)
            guard url != nil || nextURL != binding.url else { continue }
            assetImages[slot]?.url = nextURL
            guard let frames = resources.images.image(binding.source, folders: directories, packages: assetFolders),
                  frames !== binding.frames
            else { continue }
            assetImages[slot]?.frames = frames
            commands.append(.image(
                slot: slot,
                image: frames.frames.first,
                animation: animation(for: binding.handle),
                frames: frames
            ))
        }
        if !commands.isEmpty { scene.submit(commands, animated: animates && motionPolicy.animationsEnabled) }
    }

    private func layerPath(_ content: Content, text: ShellTextStore) -> ShellLayerPath {
        let box = content.params
        return ShellLayerPath(
            path: parsedPath(content.text, text: text),
            viewBox: box.z > 0 && box.w > 0
                ? CGRect(x: CGFloat(box.x), y: CGFloat(box.y), width: CGFloat(box.z), height: CGFloat(box.w))
                : nil,
            evenOdd: content.evenOdd
        )
    }

    private func parsedPath(_ id: UInt32, text: ShellTextStore) -> ShellPathData? {
        guard id != 0 else { return nil }
        let source = text.string(id)
        if let cached = pathCache[source] {
            return cached
        }
        let path = ShellPath.parse(source)
        if pathCache.count >= Self.pathCacheLimit {
            pathCache.removeAll()
        }
        pathCache[source] = path
        return path
    }

    private var loops: Bool {
        motionPolicy.animationsEnabled && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    func shaderInput(_ content: Content) -> ShellShaderInput {
        let animates = loops
        let rate = content.audio && content.rate == 0 ? 30 : Int(content.rate)
        return ShellShaderInput(
            values: content.params,
            rate: animates ? min(rate, 60) : 0,
            colors: palette.shaderColors,
            audio: content.audio,
            image: content.textureRef == 0 ? nil : text.flatMap {
                resources.images.image($0.string(content.textureRef), folders: directories, packages: assetFolders)?
                    .frames.first
            }
        )
    }

    static func motion(of content: Content, hover: Bool) -> ShellMotion? {
        ShellMotion(wire: hover && content.hoverMotion != 0 ? content.hoverMotion : content.motion)
    }

    var rootAnimation: ShellAnimation? {
        let root = layout.core.rootHandle
        guard motionPolicy.animationsEnabled, root != .none else { return nil }
        return animation(for: root)
    }

    func animation(for handle: ElementHandle, hover: Bool = false, press: Bool = false) -> ShellAnimation? {
        let content = layout.core.content(of: handle)
        let pressed = press && content.pressMotion != 0
        let hovered = !pressed && hover && content.hoverMotion != 0
        let wire = pressed ? content.pressMotion : hovered ? content.hoverMotion : content.motion
        let curveWire = pressed ? content.pressMotionCurve : hovered ? 0 : content.motionCurve
        let reference = pressed ? content.pressMotionCurveRef : hovered ? 0 : content.motionCurveRef
        let recipe = reference == 0 ? nil : text?.string(reference)
        let motion: ShellMotion?
        let curve: ShellCurve?
        if curveWire == ShellCurve.custom, let recipe, recipe.hasPrefix("spring:") {
            motion = ShellMotion(recipe: recipe)
            curve = nil
        } else {
            motion = ShellMotion(wire: wire)
            curve = ShellCurve(wire: curveWire, custom: recipe)
        }
        return motion.map {
            ShellAnimation(
                motion: $0,
                speed: motionPolicy.animationSpeed,
                curve: curve,
                trails: !hover && !press && content.trail
            )
        }
    }

    func paintCommand(
        _ handle: ElementHandle,
        _ paint: Paint,
        hover: Bool = false,
        press: Bool = false
    ) -> ShellLayerCommand {
        var paint = handle == pressed && pressInside ? Self
            .pressedPaint(paint, by: layout.core.content(of: handle)) : paint
        if paint.material >= OMNI_MATERIAL_POPOVER,
           (handle == layout.core.rootHandle && !drawsRootMaterial) || paint.material == OMNI_MATERIAL_CLEAR
        {
            paint.material = 0
        }
        let opaque = paint.material > 0 && NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        return .paint(
            slot: handle.slot,
            ShellLayerPaint(
                fill: opaque ? palette.color(paint.fill, default: .surface) : palette.color(paint.fill),
                border: palette.color(paint.stroke),
                borderWidth: CGFloat(paint.strokeWidth),
                radius: CGFloat(paint.cornerRadius),
                opacity: paint.opacity,
                scale: CGFloat(paint.scale),
                shadow: palette.color(paint.shadow),
                shadowRadius: CGFloat(paint.shadowRadius),
                material: opaque ? 0 : paint.material,
                blurRadius: CGFloat(paint.blurRadius),
                saturation: CGFloat(paint.saturation),
                enter: ShellEnter(
                    paint.enter,
                    path: text.flatMap { parsedPath(paint.enter.path, text: $0) },
                    curve: paint.enter.curveRef == 0 ? nil : text?.string(paint.enter.curveRef)
                ),
                masks: paint.masks,
                rotation: CGFloat(paint.rotate) * .pi / 180,
                quarter: layout.core.content(of: handle).style & OMNI_STYLE_QUARTER != 0,
                loop: loops && !paint.loopPaused && paint.loop != 0 ? text
                    .flatMap { ShellLoop($0.string(paint.loop)) } : nil,
                playback: loops ? ShellPlayback(speed: Double(paint.speed), paused: paint.loopPaused) : nil,
                appear: presence(paint.appear, for: handle),
                exit: presence(paint.exit, for: handle),
                frameSize: CGSize(
                    width: CGFloat(layout.core.layoutFrame(of: handle).width),
                    height: CGFloat(layout.core.layoutFrame(of: handle).height)
                )
            ),
            animation: animation(for: handle, hover: hover, press: press)
        )
    }

    private func imageCommand(
        _ handle: ElementHandle,
        _ string: String,
        color: Color,
        style: UInt32,
        text: ShellTextStore
    ) -> ShellLayerCommand? {
        switch layout.core.kind(of: handle) {
        case .symbol:
            return .image(
                slot: handle.slot,
                image: symbolImage(string, color: color, style: style),
                animation: animation(for: handle)
            )
        case .image:
            return .image(
                slot: handle.slot,
                image: iconImage(handle, text: text),
                animation: animation(for: handle)
            )
        case .bitmap:
            let content = layout.core.content(of: handle)
            if content.resourceImageRef != 0 {
                assetImages.removeValue(forKey: handle.slot)
                return resourceImageCommand(handle, content: content, text: text)
            }
            forgetResourceImage(handle)
            if string.hasPrefix(ShellAsset.prefix) {
                let frames = resources.images.image(string, folders: directories, packages: assetFolders)
                let displayed = frames ?? assetImages[handle.slot]?.frames
                assetImages[handle.slot] = AssetImageBinding(
                    handle: handle,
                    source: string,
                    url: assetURL(string),
                    frames: displayed
                )
                return .image(
                    slot: handle.slot,
                    image: displayed?.frames.first,
                    animation: animation(for: handle),
                    frames: displayed
                )
            }
            assetImages.removeValue(forKey: handle.slot)
            if let bitmap = resources.bitmap(string) {
                return .image(slot: handle.slot, image: bitmap, animation: animation(for: handle))
            }
            let frames = resources.images.image(string, folders: directories)
            return .image(
                slot: handle.slot,
                image: frames?.frames.first,
                animation: animation(for: handle),
                frames: frames
            )
        default:
            return nil
        }
    }

    private func iconImage(_ handle: ElementHandle, text: ShellTextStore) -> CGImage? {
        let content = layout.core.content(of: handle)
        let frame = layout.core.layoutFrame(of: handle)
        let side = CGFloat(max(frame.width, frame.height)) * scale
        guard side.isFinite, side > 0 else { return nil }
        let reference = text.string(content.iconSource == .bundle ? content.text : content.iconRef)
        let key = IconKey(
            source: content.iconSource,
            reference: reference,
            pixels: Int(side.rounded(.up)),
            tint: content.color
        )
        if let cached = iconImages[key] {
            return cached
        }
        guard let icon = resources.icon(content.iconSource, reference) else {
            guard content.placeholder != 0 else { return nil }
            return symbolImage(text.string(content.placeholder), color: content.color, style: content.style)
        }
        var rect = CGRect(x: 0, y: 0, width: key.pixels, height: key.pixels)
        let image = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil).map { image in
            content.color.isVisible ? tinted(image, palette.color(content.color, default: .foreground)) : image
        }
        iconImages[key] = image
        return image
    }

    private func tinted(_ image: CGImage, _ color: CGColor) -> CGImage {
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return image
        }
        context.draw(image, in: rect)
        context.setBlendMode(.sourceAtop)
        context.setFillColor(color)
        context.fill(rect)
        return context.makeImage() ?? image
    }

    private func symbolImage(_ name: String, color: Color, style: UInt32) -> CGImage? {
        let key = SymbolKey(name: name, color: color, style: style)
        if let cached = symbolImages[key] {
            return cached
        }
        let tint = NSColor(cgColor: palette.color(color, default: .foreground)) ?? .labelColor
        let pointSize = CGFloat(ShellTextStyle.symbolSize(for: style))
        let configuration = NSImage.SymbolConfiguration(
            pointSize: pointSize,
            weight: ShellTextStyle.symbolWeight(for: style)
        )
        .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        let resolved: NSImage? = switch name {
        case "omniwm": OmniWMBrandMark.tintedStatusImage(pointSize: pointSize, tint: tint)
        case "omniwm.lock": OmniWMBrandMark.secureInputStatusImage(pointSize: pointSize, tint: tint)
        default: NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        }
        guard let symbol = resolved else { return nil }
        var rect = CGRect(
            origin: .zero,
            size: CGSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
        )
        let image = symbol.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        symbolImages[key] = image
        return image
    }
}
