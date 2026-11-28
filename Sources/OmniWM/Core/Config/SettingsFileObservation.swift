// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Darwin
import Foundation

@MainActor
final class SettingsFileObservation {
    private struct FileIdentity: Equatable {
        let deviceID: UInt64
        let inode: UInt64

        init(_ fingerprint: SettingsFileAccess.Fingerprint) {
            deviceID = fingerprint.deviceID
            inode = fingerprint.inode
        }

        init(_ status: stat) {
            deviceID = UInt64(status.st_dev)
            inode = UInt64(status.st_ino)
        }
    }

    private struct Watch {
        let source: DispatchSourceFileSystemObject
        let identity: FileIdentity
    }

    private let directoryURL: URL
    private let fileURL: URL
    var onPossibleChange: (@MainActor (URL) -> Void)?
    private var directoryWatches: [URL: Watch] = [:]
    private var fileWatches: [URL: Watch] = [:]
    private var filesInDirectory: [URL: Set<URL>] = [:]
    private var started = false

    var onEventProcessed: (@MainActor (URL) -> Void)?

    init(directoryURL: URL, fileURL: URL) {
        self.directoryURL = directoryURL
        self.fileURL = fileURL
    }

    isolated deinit {
        for watch in fileWatches.values { watch.source.cancel() }
        for watch in directoryWatches.values {
            watch.source.cancel()
        }
    }

    func start() {
        guard !started else { return }
        started = true
        do {
            try SettingsFileAccess.ensureDirectoryExists(at: directoryURL)
        } catch {
            Log.config.error("Failed to create settings directory \(directoryURL.path): \(error.localizedDescription)")
        }
        refresh()
    }

    func refresh(for observedFingerprint: SettingsFileAccess.Fingerprint? = nil) {
        let fingerprint = observedFingerprint ?? SettingsFileAccess.currentFingerprint(at: fileURL)
        refresh(files: [fileURL: fingerprint])
    }

    func refresh(files: [URL: SettingsFileAccess.Fingerprint?]) {
        guard started else { return }
        var directories: [URL: Set<URL>] = [:]
        for (url, fingerprint) in files {
            for parent in SettingsFileObservationDirectories.paths(for: url) {
                directories[parent, default: []].insert(url)
            }
            refreshWatch(at: url, fingerprint: fingerprint, watches: &fileWatches)
        }
        for url in fileWatches.keys where !files.keys.contains(url) {
            fileWatches.removeValue(forKey: url)?.source.cancel()
        }
        for parent in directories.keys {
            refreshWatch(
                at: parent,
                fingerprint: SettingsFileAccess.currentFingerprint(at: parent),
                watches: &directoryWatches
            )
        }
        for parent in directoryWatches.keys where directories[parent] == nil {
            directoryWatches.removeValue(forKey: parent)?.source.cancel()
        }
        filesInDirectory = directories
    }

    func filesAffected(by url: URL) -> Set<URL> {
        filesInDirectory[url] ?? [url]
    }

    private func refreshWatch(at url: URL, fingerprint: SettingsFileAccess.Fingerprint?, watches: inout [URL: Watch]) {
        guard let fingerprint else {
            watches.removeValue(forKey: url)?.source.cancel()
            return
        }
        guard watches[url]?.identity != FileIdentity(fingerprint) else { return }
        watches.removeValue(forKey: url)?.source.cancel()
        watches[url] = makeWatch(at: url)
    }

    func stop() {
        started = false
        for watch in fileWatches.values { watch.source.cancel() }
        for watch in directoryWatches.values { watch.source.cancel() }
        fileWatches.removeAll()
        directoryWatches.removeAll()
        filesInDirectory.removeAll()
    }

    func isWatchingDirectory(at url: URL) -> Bool {
        guard let watch = directoryWatches.first(where: { $0.key.path == url.path })?.value,
              let fingerprint = SettingsFileAccess.currentFingerprint(at: url)
        else { return false }
        return watch.identity == FileIdentity(fingerprint)
    }

    private func makeWatch(at url: URL) -> Watch? {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            Log.config.error("Failed to watch settings path \(url.path).")
            return nil
        }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            close(descriptor)
            return nil
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            onPossibleChange?(url)
            onEventProcessed?(url)
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        return Watch(source: source, identity: FileIdentity(status))
    }
}
