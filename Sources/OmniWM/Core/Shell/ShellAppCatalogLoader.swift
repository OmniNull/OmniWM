// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

actor ShellAppCatalogLoader {
    struct Snapshot: Sendable {
        var definitions: [String: ShellAppDefinition] = [:]
        var problems: [String] = []
        var folders: [URL] = []
    }

    private let queue = DispatchSerialQueue(label: "com.omniwm.shell.apps", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    func load(directories: [URL], bundled: URL?) async throws -> Snapshot {
        var result = Snapshot()
        var candidates: [URL] = [bundled].compactMap { $0 }
        for directory in directories.sorted(by: { $0.path < $1.path }) {
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            do {
                candidates += try FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
                )
                .filter {
                    try $0.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                }
                .sorted { $0.path < $1.path }
            } catch { result.problems.append("\(directory.path): \(error.localizedDescription)") }
        }
        result.folders = candidates.flatMap { [$0] + ShellWidgetSourceLoader.entries(in: $0, directories: true) }
        var owners: [String: URL] = [:]
        for folder in candidates {
            try Task.checkCancellation()
            let id = folder.lastPathComponent
            if let owner = owners[id] {
                result.problems.append("\(folder.path): app id \(id) is already provided by \(owner.path)")
                continue
            }
            owners[id] = folder
            do {
                let definition = try ShellAppDefinition.load(id: id, folder: folder)
                let source = try definition.source(validatingViews: true)
                let package = ShellWidgetPackage(name: "app-validation.\(id)", generation: 1, outbox: .init { _ in })
                let failure = await package.validateReload(source)
                await package.close()
                if let failure { throw failure }
                result.definitions[id] = definition
            } catch is CancellationError { throw CancellationError() }
            catch { result.problems.append("\(folder.path): \(error.localizedDescription)") }
        }
        return result
    }
}
