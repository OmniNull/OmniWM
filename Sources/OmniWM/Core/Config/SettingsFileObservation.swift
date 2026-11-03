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
    private weak var persistence: SettingsFilePersistence?
    private var directoryWatches: [URL: Watch] = [:]
    private var settingsFileWatch: Watch?
    private var started = false

    var onEventProcessed: (@MainActor (URL) -> Void)?

    init(directoryURL: URL, fileURL: URL) {
        self.directoryURL = directoryURL
        self.fileURL = fileURL
    }

    isolated deinit {
        settingsFileWatch?.source.cancel()
        for watch in directoryWatches.values {
            watch.source.cancel()
        }
    }

    func attach(to persistence: SettingsFilePersistence) {
        precondition(self.persistence == nil)
        self.persistence = persistence
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
        refreshDirectoryWatches()

        let fingerprint = observedFingerprint ?? SettingsFileAccess.currentFingerprint(at: fileURL)
        guard let fingerprint else {
            settingsFileWatch?.source.cancel()
            settingsFileWatch = nil
            return
        }
        guard settingsFileWatch?.identity != FileIdentity(fingerprint) else { return }
        settingsFileWatch?.source.cancel()
        settingsFileWatch = makeWatch(at: fileURL)
    }

    func isWatchingDirectory(at url: URL) -> Bool {
        guard let watch = directoryWatches.first(where: { $0.key.path == url.path })?.value,
              let fingerprint = SettingsFileAccess.currentFingerprint(at: url)
        else { return false }
        return watch.identity == FileIdentity(fingerprint)
    }

    private func refreshDirectoryWatches() {
        guard started else { return }
        let directories = SettingsFileObservationDirectories.paths(for: fileURL)
        for directory in directories {
            let identity = SettingsFileAccess.currentFingerprint(at: directory).map(FileIdentity.init)
            if let watch = directoryWatches[directory], watch.identity == identity { continue }
            directoryWatches.removeValue(forKey: directory)?.source.cancel()
            directoryWatches[directory] = makeWatch(at: directory)
        }
        for directory in directoryWatches.keys where !directories.contains(directory) {
            directoryWatches.removeValue(forKey: directory)?.source.cancel()
        }
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
            persistence?.handlePossibleSettingsFileChange()
            onEventProcessed?(url)
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        return Watch(source: source, identity: FileIdentity(status))
    }
}
