// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWMCtl
import XCTest

enum NuCompletionTestSupport {
    static func completions(_ commandLines: [String]) throws -> [[String]] {
        let list = try commandLines.map(literal).joined(separator: ", ")
        let output = try run("[\(list)] | each { |line| $line | commandline complete | default [] } | to json")
        let results = try JSONDecoder().decode([[String]].self, from: output)
        guard results.count == commandLines.count else {
            throw Failure.resultCount(expected: commandLines.count, output: String(decoding: output, as: UTF8.self))
        }
        return results
    }

    static func run(_ body: String) throws -> Data {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let executable = try nuExecutable(path: path)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMNuCompletion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let module = directory.appendingPathComponent("completions.nu")
        try CLICompletionGenerator.script(for: .nu).write(to: module, atomically: true, encoding: .utf8)
        let fixture = directory.appendingPathComponent("omniwmctl")
        try "#!/bin/sh\n/usr/bin/printf '%s\\0' \"$@\"\n"
            .write(to: fixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.path)

        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-n", "-c", "use \(try literal(module.path)) omniwmctl; \(body)"]
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging(["PATH": "\(directory.path):\(path)"]) {
            _, replacement in replacement
        }
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw Failure.shell(process.terminationStatus, String(decoding: errorData, as: UTF8.self))
        }
        return data
    }

    private static func literal(_ value: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func nuExecutable(path: String) throws -> String {
        guard let executable = path.split(separator: ":")
            .map({ URL(fileURLWithPath: String($0)).appendingPathComponent("nu").path })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else {
            throw XCTSkip("Nushell is not installed")
        }
        return executable
    }

    private enum Failure: Error {
        case shell(Int32, String)
        case resultCount(expected: Int, output: String)
    }
}
