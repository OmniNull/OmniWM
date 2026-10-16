// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import Metal
import Synchronization

enum ShellShaderGPU {
    static let device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()
    static let queue: (any MTLCommandQueue)? = device?.makeCommandQueue()
}

struct ShellShaderUniforms {
    var size: SIMD2<Float>
    var scale: Float
    var time: Float
    var values: SIMD4<Float>
    var colors: ShellShaderInput.Colors
    var progress: Float
    var anchor: SIMD2<Float>
    var content: SIMD4<Float>
    var audio: ShellSpectrumBands.Bars
}

struct ShellShaderStage: Equatable, Sendable {
    var anchor: CGPoint
    var content: CGRect
}

struct ShellShaderTransition: Equatable, Sendable {
    static let settled = ShellShaderTransition(from: 1, to: 1, start: 0, duration: 0)

    var from: Float
    var to: Float
    var start: CFTimeInterval
    var duration: CFTimeInterval
    var forced = false

    static func opening(_ timing: ShellTiming, standard: CFTimeInterval?, at now: CFTimeInterval) -> Self {
        guard let open = timing.open else {
            return ShellShaderTransition(from: 0, to: 1, start: now, duration: standard ?? 0)
        }
        return ShellShaderTransition(from: 0, to: 1, start: now, duration: open, forced: true)
    }

    static func closing(
        from progress: Float,
        _ timing: ShellTiming,
        standard: CFTimeInterval?,
        at now: CFTimeInterval
    ) -> Self {
        guard let close = timing.close else {
            return ShellShaderTransition(from: progress, to: 0, start: now, duration: standard ?? 0)
        }
        return ShellShaderTransition(
            from: progress,
            to: 0,
            start: now,
            duration: close * Double(progress),
            forced: true
        )
    }

    func progress(at now: CFTimeInterval) -> Float {
        guard duration > 0 else { return to }
        let fraction = Float(min(max((now - start) / duration, 0), 1))
        return from + (to - from) * fraction
    }

    func drivesFrames(at now: CFTimeInterval) -> Bool {
        forced && duration > 0 && now < start + duration
    }
}

struct ShellTiming: Equatable, Sendable {
    var open: CFTimeInterval?
    var close: CFTimeInterval?

    init(open: Float = -1, close: Float = -1) {
        self.open = open >= 0 ? CFTimeInterval(open) : nil
        self.close = close >= 0 ? CFTimeInterval(close) : nil
    }
}

struct ShellShaderInput: Sendable {
    typealias Colors = InlineArray<40, SIMD4<Float>>

    var values: SIMD4<Float>
    var rate: Int
    var colors: Colors
    var audio = false
    var image: CGImage?
}

final class ShellShaderProgram: Sendable {
    private enum State {
        case compiling
        case ready(any MTLRenderPipelineState)
        case failed(String)
    }

    let name: String
    let url: URL?
    private let state: Mutex<State>
    private let changed: @Sendable () -> Void

    init(name: String, url: URL? = nil, failure: String? = nil, changed: @escaping @Sendable () -> Void = {}) {
        self.name = name
        self.url = url
        state = Mutex(failure.map(State.failed) ?? .compiling)
        self.changed = changed
    }

    var pipeline: (any MTLRenderPipelineState)? {
        state.withLock { state in
            guard case let .ready(pipeline) = state else { return nil }
            return pipeline
        }
    }

    var failure: String? {
        state.withLock { state in
            guard case let .failed(message) = state else { return nil }
            return "\(name): \(message)"
        }
    }

    var isCompiling: Bool {
        state.withLock { state in
            guard case .compiling = state else { return false }
            return true
        }
    }

    func finish(_ pipeline: (any MTLRenderPipelineState)?, failure: String?) {
        state.withLock { state in
            state = pipeline.map(State.ready) ?? .failed(failure ?? "the shader did not compile")
        }
        changed()
    }

    func fail(_ message: String) {
        let failed = state.withLock { state in
            guard case .ready = state else { return false }
            state = .failed(message)
            return true
        }
        if failed {
            changed()
        }
    }
}

actor ShellShaderPreparation {
    struct Prepared: Sendable {
        let revision: ShellAssetRevision
        let pipeline: any MTLRenderPipelineState
    }

    private let queue = DispatchSerialQueue(label: "com.barut.OmniWM.shell.shaders", qos: .utility)
    private var entries: [URL: Prepared] = [:]

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    func prepare(_ asset: ShellAsset) throws -> Prepared {
        let revision = try asset.revision(limit: ShellShaderLibrary.sourceLimit)
        if let cached = entries[revision.url], cached.revision == revision { return cached }
        let contents = try SettingsFileAccess.readContents(at: revision.url)
        let prepared = Prepared(
            revision: ShellAssetRevision(url: revision.url, fingerprint: contents.fingerprint),
            pipeline: try ShellShaderLibrary.pipeline(contents.data, name: asset.path)
        )
        entries[revision.url] = prepared
        return prepared
    }
}

@MainActor
final class ShellShaderLibrary {
    nonisolated static let sourceLimit = 256 * 1024

    private struct Entry {
        let program: ShellShaderProgram
        let fingerprint: SettingsFileAccess.Fingerprint?
    }

    private struct AssetEntry {
        var program: ShellShaderProgram
        var revision: ShellAssetRevision?
        var loading = false
        var invalidated = false
    }

    var onChange: (@MainActor () -> Void)?
    var onAssetChange: (@MainActor (URL) -> Void)?
    private var entries: [URL: Entry] = [:]
    private var assets: [ShellAsset: AssetEntry] = [:]
    private let preparation = ShellShaderPreparation()
    private static let compileQueue = DispatchSerialQueue(label: "com.barut.OmniWM.shell.shader-source", qos: .utility)

    var files: [URL] {
        Array(Set(entries.keys).union(assets.keys.map(\.url)).union(assets.values.compactMap { $0.revision?.url }))
    }

    func program(source: String, directories: [URL], packages: [String: URL] = [:]) -> ShellShaderProgram {
        if source.hasPrefix(ShellAsset.prefix) {
            do {
                let asset = try ShellAsset(source, packages: packages)
                if let entry = assets[asset] { return entry.program }
                let program = assetProgram(asset)
                assets[asset] = AssetEntry(program: program)
                prepare(asset)
                return program
            } catch {
                return ShellShaderProgram(name: source, failure: String(describing: error))
            }
        }
        guard !source.isEmpty, !source.contains("/"), source != ".", source != ".." else {
            return ShellShaderProgram(name: source, failure: "a shader source must be a file name such as glow.metal")
        }
        let found = directories.lazy
            .map { $0.appendingPathComponent(source) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        guard let url = found else {
            return ShellShaderProgram(name: source, failure: "not found in the widget folder or a shaders folder")
        }
        if let entry = entries[url] {
            return entry.program
        }
        let program = compile(url, name: source)
        entries[url] = Entry(program: program, fingerprint: SettingsFileAccess.currentFingerprint(at: url))
        return program
    }

    func refresh() {
        for asset in assets.keys { prepare(asset) }
        entries = entries.filter { SettingsFileAccess.currentFingerprint(at: $0.key) == $0.value.fingerprint }
    }

    private func assetProgram(_ asset: ShellAsset) -> ShellShaderProgram {
        ShellShaderProgram(name: asset.path, url: asset.url) { [weak self] in
            Task { @MainActor in self?.onAssetChange?(asset.url) }
        }
    }

    private func prepare(_ asset: ShellAsset) {
        guard assets[asset]?.loading != true else {
            assets[asset]?.invalidated = true
            return
        }
        assets[asset]?.loading = true
        Task { [weak self, preparation] in
            let result: Result<ShellShaderPreparation.Prepared, any Error>
            do { result = .success(try await preparation.prepare(asset)) }
            catch { result = .failure(error) }
            guard let self, var entry = assets[asset] else { return }
            let again = entry.invalidated
            entry.loading = false
            entry.invalidated = false
            switch result {
            case let .success(prepared):
                let changed = entry.revision != prepared.revision
                if changed {
                    if entry.revision != nil { entry.program = assetProgram(asset) }
                    entry.revision = prepared.revision
                }
                assets[asset] = entry
                if changed { entry.program.finish(prepared.pipeline, failure: nil) }
            case let .failure(error):
                assets[asset] = entry
                if entry.revision == nil {
                    entry.program.finish(nil, failure: String(describing: error))
                } else {
                    Log.shell.error("\(asset.path): \(String(describing: error))")
                }
            }
            if again { prepare(asset) }
        }
    }

    private func compile(_ url: URL, name: String) -> ShellShaderProgram {
        let program = ShellShaderProgram(name: name, url: url) { [weak self] in
            Task { @MainActor in
                self?.onChange?()
            }
        }
        Self.compileQueue.async {
            do {
                let data = try SettingsFileAccess.readContents(at: url).data
                program.finish(try Self.pipeline(data, name: name), failure: nil)
            } catch {
                program.finish(nil, failure: Self.message(error))
            }
        }
        return program
    }

    nonisolated static func pipeline(_ data: Data, name: String) throws -> any MTLRenderPipelineState {
        guard data.count <= sourceLimit else { throw ShellAsset.Failure.invalid("larger than 256 KiB") }
        guard let device = ShellShaderGPU.device else { throw ShellAsset.Failure.invalid("Metal is not available") }
        let library = try device.makeLibrary(
            source: wrap(String(decoding: data, as: UTF8.self), name: name),
            options: nil
        )
        guard let vertex = library.makeFunction(name: "omni_vertex"),
              let fragment = library.makeFunction(name: "omni_fragment")
        else { throw ShellAsset.Failure.invalid("the shader did not compile") }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private nonisolated static func message(_ error: (any Error)?) -> String {
        guard let error else { return "the shader did not compile" }
        let lines = error.localizedDescription
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "Compilation failed:" }
        return lines.prefix(3).joined(separator: " ")
    }

    private nonisolated static let shaderFunctions = """
    float omni_progress(constant OmniShader& shader) {
        if (shader.values.w < -1.5) return 0.5 - 0.5 * cos(shader.time * M_PI_F / 1.5);
        return clamp(shader.values.w < 0.0 ? shader.progress : shader.values.w, 0.0, 1.0);
    }
    float omni_noise(float2 point) {
        float2 cell = floor(point);
        float2 local = fract(point);
        local = local * local * (3.0 - 2.0 * local);
        float4 hashes = fract(sin(float4(dot(cell, float2(127.1, 311.7)),
            dot(cell + float2(1, 0), float2(127.1, 311.7)),
            dot(cell + float2(0, 1), float2(127.1, 311.7)),
            dot(cell + 1.0, float2(127.1, 311.7)))) * 43758.5453);
        return mix(mix(hashes.x, hashes.y, local.x), mix(hashes.z, hashes.w, local.x), local.y);
    }
    float4 omni_sample(texture2d<float> image, float2 uv) {
        if (any(uv < 0.0) || any(uv > 1.0)) return float4(0);
        constexpr sampler sampling(coord::normalized, address::clamp_to_edge, filter::linear);
        float4 color = image.sample(sampling, uv);
        return color.a > 0 ? float4(color.rgb / color.a, color.a) : float4(0);
    }
    """

    private nonisolated static let fragmentEntryPoint = """
    fragment half4 omni_fragment(OmniVertex in [[stage_in]], constant OmniShader& shader [[buffer(0)]],
                                 texture2d<float> image [[texture(0)]]) {
    #ifdef OMNI_TEXTURE
        float4 color = shade(in.uv, shader, image);
    #else
        float4 color = shade(in.uv, shader);
    #endif
        return half4(float4(color.rgb * color.a, color.a));
    }
    """

    nonisolated static func wrap(_ source: String, name: String) -> String {
        let roles = ShellRole.allCases.prefix(ShellShaderInput.Colors.count)
            .map { "constant int omni_\($0) = \($0.rawValue);" }
            .joined(separator: "\n")
        return """
        #include <metal_stdlib>
        using namespace metal;
        struct OmniShader {
            float2 size;
            float scale;
            float time;
            float4 values;
            float4 colors[\(ShellShaderInput.Colors.count)];
            float progress;
            float2 anchor;
            float4 content;
            float audio[\(ShellSpectrumBands.Bars.count)];
        };
        \(roles)
        struct OmniVertex {
            float4 position [[position]];
            float2 uv;
        };
        vertex OmniVertex omni_vertex(uint id [[vertex_id]]) {
            float2 uv = float2((id << 1) & 2, id & 2);
            OmniVertex out;
            out.position = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
            out.uv = uv;
            return out;
        }
        \(shaderFunctions)
        #line 1 "\(name)"
        \(source)
        #line 1 "omniwm"
        \(fragmentEntryPoint)
        """
    }
}
