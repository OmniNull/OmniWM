// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMScriptHost
import QuartzCore
import XCTest

let failureBound: TimeInterval = 30

func floatStored<T: BinaryFloatingPoint>(_ value: T) -> T {
    T(Float(value))
}

extension BinaryFloatingPoint {
    static func rounding(operations: Int, at magnitude: Self) -> Self {
        Self(operations) * abs(magnitude).ulp
    }
}

struct MissingTestPrerequisite: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

func boundedChanges() -> (changes: AsyncStream<Void>, changed: AsyncStream<Void>.Continuation) {
    let (changes, changed) = AsyncStream.makeStream(of: Void.self)
    DispatchQueue.main.asyncAfter(deadline: .now() + failureBound) { changed.finish() }
    return (changes, changed)
}

extension AsyncStream<Void> {
    @MainActor
    func wait(
        _ description: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
        arming arm: () -> Void = {},
        until condition: () -> Bool
    ) async {
        var iterator = makeAsyncIterator()
        while !condition() {
            arm()
            guard await iterator.next() != nil else {
                let detail = description()
                XCTFail(
                    "The condition did not hold when the changes ended\(detail.isEmpty ? "" : ": \(detail)")",
                    file: file,
                    line: line
                )
                return
            }
        }
    }
}

@MainActor
func waitForApply(
    to surfaces: [ShellWidgetSurface],
    file: StaticString = #filePath,
    line: UInt = #line,
    until condition: () -> Bool
) async {
    let (changes, changed) = boundedChanges()
    let installed = surfaces.map(\.onMove)
    for (surface, onMove) in zip(surfaces, installed) {
        surface.onMove = {
            onMove?()
            changed.yield()
        }
    }
    defer {
        for (surface, onMove) in zip(surfaces, installed) {
            surface.onMove = onMove
        }
    }
    await changes.wait(file: file, line: line, until: condition)
}

@MainActor
func waitForWidgetReport(
    of host: ShellWidgetHost,
    _ description: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    until condition: () -> Bool
) async {
    let (changes, changed) = boundedChanges()
    let published = host.onWidgetsChange
    host.onWidgetsChange = {
        published?()
        changed.yield()
    }
    defer { host.onWidgetsChange = published }
    await changes.wait(description(), file: file, line: line, until: condition)
}

@MainActor
func waitForShaders(
    in library: ShellShaderLibrary,
    file: StaticString = #filePath,
    line: UInt = #line,
    until condition: () -> Bool
) async {
    let (changes, changed) = boundedChanges()
    let onChange = library.onChange
    let onAssetChange = library.onAssetChange
    library.onChange = {
        onChange?()
        changed.yield()
    }
    library.onAssetChange = { url in
        onAssetChange?(url)
        changed.yield()
    }
    defer {
        library.onChange = onChange
        library.onAssetChange = onAssetChange
    }
    await changes.wait(file: file, line: line, until: condition)
}

@MainActor
func waitForFrames(
    in scene: ShellLayerScene,
    file: StaticString = #filePath,
    line: UInt = #line,
    until condition: () -> Bool
) async {
    let (changes, changed) = boundedChanges()
    let observations = ShellLayerScene.engineQueue.sync {
        scene.layers.values.map { $0.observe(\.contents) { _, _ in changed.yield() } }
    }
    defer { ShellLayerScene.engineQueue.sync { observations.forEach { $0.invalidate() } } }
    await changes.wait(file: file, line: line, until: condition)
}

struct LayoutChangeMissing: Error, CustomStringConvertible {
    var description: String {
        "no change arrived"
    }
}

extension AsyncStream<Void>.Iterator {
    mutating func change(file: StaticString = #filePath, line: UInt = #line) async throws {
        guard await next() != nil else {
            XCTFail("No change arrived before the stream ended", file: file, line: line)
            throw LayoutChangeMissing()
        }
    }
}

extension ShellRequest {
    init?(_ text: String) {
        self.init(words: text.split(whereSeparator: \.isWhitespace).map(String.init))
    }
}

extension ShellConfig {
    static func load(shellDirectory: URL) -> ShellConfig? {
        var problems: [String] = []
        return load(shellDirectory: shellDirectory, problems: &problems)
    }
}

extension ShellWidgetPackage {
    func load(source: String) async -> ShellScriptFailure? {
        await load(ShellWidgetSource(chunk: "=\(name)", main: source, modules: []))
    }
}

extension CALayer {
    var flattened: [CALayer] {
        [self] + (sublayers ?? []).flatMap(\.flattened)
    }
}

extension ShellTextStore {
    func ingest(wire output: [UInt8]) {
        output.withUnsafeBytes { buffer in
            let header = buffer.loadUnaligned(as: omni_wire_header.self)
            let offset = MemoryLayout<omni_wire_header>.stride
                + Int(header.node_count) * MemoryLayout<omni_wire_node>.stride
            ingest(Array(buffer[offset...]), count: Int(header.string_count))
        }
    }
}
