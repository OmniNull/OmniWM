// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMScriptHost
import QuartzCore
import XCTest

@MainActor
func until(
    _ description: @autoclosure () -> String = "",
    timeout: Duration = .seconds(20),
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            let detail = description()
            XCTFail(
                "The condition did not hold within \(timeout)\(detail.isEmpty ? "" : ": \(detail)")",
                file: file,
                line: line
            )
            return
        }
        await Task.yield()
    }
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
