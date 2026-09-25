// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Observation
import OmniWMLauncherSPI
import QuickLookThumbnailing

@MainActor
@Observable
final class LauncherIconStore {
    static let shared = LauncherIconStore()

    private struct Key: Hashable, Sendable {
        let path: String
        let sequence: UInt64
        let pixels: Int
    }

    @MainActor
    @Observable
    final class ImageBox {
        var image: NSImage?
    }

    private let renderQueue = DispatchQueue(
        label: "com.barut.OmniWM.launcher.icons",
        qos: .utility
    )
    @ObservationIgnored private var applicationBoxes: [Key: ImageBox] = [:]
    @ObservationIgnored private var fileBoxes: [Key: ImageBox] = [:]
    @ObservationIgnored private var pendingApplicationIcons: Set<Key> = []
    @ObservationIgnored private var fileTasks: [Key: Task<Void, Never>] = [:]
    @ObservationIgnored private var fileRequests: [Key: QLThumbnailGenerator.Request] = [:]
    @ObservationIgnored private var fileOrder: [Key] = []
    private(set) var cacheGeneration: UInt64 = 0

    func applicationIcon(for item: LauncherApplicationResult, points: CGFloat, scale: CGFloat) -> NSImage? {
        applicationBox(for: Key(path: item.id, sequence: item.recordSequence, pixels: Int(points * scale))).image
    }

    func fileThumbnail(for item: LauncherFileResult, points: CGFloat, scale: CGFloat) -> NSImage? {
        fileBox(for: Key(path: item.id, sequence: 0, pixels: Int(points * scale))).image
    }

    func loadApplicationIcon(for item: LauncherApplicationResult, points: CGFloat, scale: CGFloat) {
        let key = Key(path: item.id, sequence: item.recordSequence, pixels: Int(points * scale))
        guard applicationBox(for: key).image == nil, pendingApplicationIcons.insert(key).inserted else { return }
        let generation = cacheGeneration
        renderQueue.async { [weak self] in
            let image = omniwm_launcher_create_icon(URL(fileURLWithPath: key.path) as CFURL, points, scale)
            Task { @MainActor [weak self] in
                guard let self, self.cacheGeneration == generation else { return }
                self.pendingApplicationIcons.remove(key)
                if let image {
                    self.applicationBoxes[key]?.image = NSImage(
                        cgImage: image,
                        size: NSSize(width: points, height: points)
                    )
                }
            }
        }
    }

    func loadFileThumbnail(for item: LauncherFileResult, points: CGFloat, scale: CGFloat) {
        let key = Key(path: item.id, sequence: 0, pixels: Int(points * scale))
        guard fileBox(for: key).image == nil, fileTasks[key] == nil else { return }
        let generation = cacheGeneration
        let request = QLThumbnailGenerator.Request(
            fileAt: item.fileURL,
            size: CGSize(width: points, height: points),
            scale: scale,
            representationTypes: [.thumbnail, .icon]
        )
        fileRequests[key] = request
        fileTasks[key] = Task { [weak self] in
            let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            guard !Task.isCancelled else { return }
            guard self?.cacheGeneration == generation else { return }
            if let representation {
                self?.fileBoxes[key]?.image = NSImage(
                    cgImage: representation.cgImage,
                    size: NSSize(width: points, height: points)
                )
                self?.fileOrder.removeAll { $0 == key }
                self?.fileOrder.append(key)
                self?.trimFileCache()
            }
            self?.fileTasks[key] = nil
            self?.fileRequests[key] = nil
        }
    }

    func cancelFileThumbnail(for item: LauncherFileResult, points: CGFloat, scale: CGFloat) {
        let key = Key(path: item.id, sequence: 0, pixels: Int(points * scale))
        fileTasks[key]?.cancel()
        fileTasks[key] = nil
        if let request = fileRequests.removeValue(forKey: key) {
            QLThumbnailGenerator.shared.cancel(request)
        }
        if fileBoxes[key]?.image == nil {
            fileBoxes[key] = nil
        }
    }

    func clear() {
        cacheGeneration &+= 1
        cancelAllFileThumbnails()
        pendingApplicationIcons.removeAll()
        applicationBoxes.removeAll()
        fileBoxes.removeAll()
        fileOrder.removeAll()
    }

    func cancelAllFileThumbnails() {
        fileTasks.values.forEach { $0.cancel() }
        fileRequests.values.forEach { QLThumbnailGenerator.shared.cancel($0) }
        fileTasks.removeAll()
        fileRequests.removeAll()
    }

    private func trimFileCache() {
        while fileOrder.count > 128 {
            fileBoxes.removeValue(forKey: fileOrder.removeFirst())
        }
    }

    private func applicationBox(for key: Key) -> ImageBox {
        if let box = applicationBoxes[key] { return box }
        let box = ImageBox()
        applicationBoxes[key] = box
        return box
    }

    private func fileBox(for key: Key) -> ImageBox {
        if let box = fileBoxes[key] { return box }
        let box = ImageBox()
        fileBoxes[key] = box
        return box
    }
}
