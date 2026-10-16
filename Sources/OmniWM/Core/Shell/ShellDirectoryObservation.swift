// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Darwin
import Foundation

@MainActor
final class ShellDirectoryObservation {
    private struct Watch {
        let source: DispatchSourceFileSystemObject
        let identity: UInt64
    }

    private let onChange: @MainActor () -> Void
    private var watches: [String: Watch] = [:]

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    isolated deinit {
        cancel()
    }

    func sync(paths: [URL]) {
        var wanted = Set<String>()
        for url in paths {
            let path = url.path
            wanted.insert(path)
            let identity = SettingsFileAccess.currentFingerprint(at: url)?.inode
            if let existing = watches[path], existing.identity == identity {
                continue
            }
            watches.removeValue(forKey: path)?.source.cancel()
            if let identity, let source = makeSource(path: path) {
                watches[path] = Watch(source: source, identity: identity)
            }
        }
        for path in watches.keys where !wanted.contains(path) {
            watches.removeValue(forKey: path)?.source.cancel()
        }
    }

    func cancel() {
        for watch in watches.values {
            watch.source.cancel()
        }
        watches.removeAll()
    }

    private func makeSource(path: String) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.onChange()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        return source
    }
}
