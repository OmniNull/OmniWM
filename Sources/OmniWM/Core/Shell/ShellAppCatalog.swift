// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import Observation

@MainActor
@Observable
final class ShellAppCatalog {
    let directory: URL
    private let bundled: URL?
    private(set) var definitions: [String: ShellAppDefinition] = [:]
    private(set) var problems: [String] = []
    @ObservationIgnored private let loader = ShellAppCatalogLoader()
    @ObservationIgnored private var observation: ShellDirectoryObservation?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var revision: UInt64 = 0

    init(configDirectory: URL, bundle: Bundle = .module) {
        directory = configDirectory.appendingPathComponent("apps", isDirectory: true)
        let example = ShellAppDefinition.example(in: bundle)
        bundled = example?.folder
        if let example { definitions[example.id] = example }
    }

    func startObserving() {
        guard observation == nil else { return }
        observation = ShellDirectoryObservation(watchLinks: true) { [weak self] in self?.requestRefresh() }
        watch([])
        requestRefresh()
    }

    func stopObserving() {
        observation?.cancel()
        observation = nil
        reloadTask?.cancel()
        reloadTask = nil
        revision += 1
    }

    func requestRefresh() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in await self?.refresh() }
    }

    func refresh() async {
        revision += 1
        let requested = revision
        do {
            let snapshot = try await loader.load(directories: [directory], bundled: bundled)
            try Task.checkCancellation()
            guard revision == requested else { return }
            definitions = snapshot.definitions
            problems = snapshot.problems
            watch(snapshot.folders)
        } catch is CancellationError {
        } catch {
            guard revision == requested else { return }
            problems = ["\(directory.path): \(error.localizedDescription)"]
        }
    }

    private func watch(_ folders: [URL]) {
        observation?.sync(
            paths: [directory.deletingLastPathComponent(), directory] + folders,
            recursivePaths: [directory] + folders
        )
    }
}
