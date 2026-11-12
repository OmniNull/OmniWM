// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ShellImageConversionFormat: String, CaseIterable, Sendable {
    case png, jpeg, tiff

    var type: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .tiff: .tiff
        }
    }

    var suffix: String {
        self == .jpeg ? "jpg" : rawValue
    }
}

struct ShellConvertedImages: Sendable {
    let files: [ShellResourceOutput]
    let descriptors: [ShellPickedResource]
}

enum ShellImageConversionState {
    case idle
    case running
    case finished
}

extension ShellResourceStore {
    func convertImages(
        _ key: ShellResourceLeaseKey,
        format: ShellImageConversionFormat,
        progress: @Sendable (Int, Int) -> Void
    ) async throws -> ShellConvertedImages {
        guard catalog.isActive(key.id.owner), let conversion = try actions[key]?.beginImageConversion()
        else { throw ShellResourceFailure("invalid_conversion") }
        defer {
            let completion = actions[key]?.endImageConversion()
            if completion?.cancelled == true || !catalog.isActive(key.id.owner) { finishAction(key) }
            for waiter in completion?.waiters ?? [] { waiter.resume() }
        }
        return try await conversion.run(format: format, progress: progress)
    }

    struct ImageConversion: Sendable {
        let operation: ShellResourceOperation
        let inputs: [ShellResourceID]
        let files: [ShellResourceID: ShellResourceFile]
        let directory: URL

        @concurrent
        consuming func run(
            format: ShellImageConversionFormat,
            progress: @Sendable (Int, Int) -> Void
        ) async throws -> ShellConvertedImages {
            var files: [ShellResourceOutput] = []
            var descriptors: [ShellPickedResource] = []
            files.reserveCapacity(inputs.count)
            descriptors.reserveCapacity(inputs.count)
            progress(0, inputs.count)
            for (index, id) in inputs.enumerated() {
                guard operation.isActive, let input = self.files[id] else {
                    throw ShellResourceFailure("cancelled")
                }
                let name = Self.convertedImageName(input.name, index: index, format: format)
                let destination = directory.appendingPathComponent(name)
                try autoreleasepool {
                    guard let source = CGImageSourceCreateWithURL(input.url as CFURL, nil),
                          CGImageSourceGetCount(source) > 0,
                          let output = CGImageDestinationCreateWithURL(
                              destination as CFURL,
                              format.type.identifier as CFString,
                              1,
                              nil
                          )
                    else { throw ShellResourceFailure("invalid_image") }
                    CGImageDestinationAddImageFromSource(output, source, 0, nil)
                    guard operation.isActive else { throw ShellResourceFailure("cancelled") }
                    guard CGImageDestinationFinalize(output) else { throw ShellResourceFailure("conversion_failed") }
                }
                guard operation.isActive else { throw ShellResourceFailure("cancelled") }
                files.append(ShellResourceOutput(name: name, path: name))
                descriptors.append(ShellPickedResource(name: name, kind: "file", uti: format.type.identifier))
                progress(index + 1, inputs.count)
            }
            guard operation.isActive else { throw ShellResourceFailure("cancelled") }
            return ShellConvertedImages(files: files, descriptors: descriptors)
        }

        private static func convertedImageName(
            _ name: String,
            index: Int,
            format: ShellImageConversionFormat
        ) -> String {
            let stem = ((name as NSString).lastPathComponent as NSString).deletingPathExtension
            let safe = String(stem.unicodeScalars.map { value -> Character in
                switch value.value {
                case 45,
                     46,
                     48 ... 57,
                     65 ... 90,
                     95,
                     97 ... 122: Character(value)
                default: "_"
                }
            }.prefix(80))
            return String(format: "%02d", index + 1) + "-" + (safe.isEmpty ? "image" : safe) + "." + format.suffix
        }
    }
}

extension ShellResourceStore.Action {
    mutating func beginImageConversion() throws -> ShellResourceStore.ImageConversion {
        guard pending.isEmpty, completion == nil, operation.isActive,
              !inputs.isEmpty, inputs.count <= ShellResourceStore.attachmentLimit, case .idle = conversion
        else { throw ShellResourceFailure("invalid_conversion") }
        conversion = .running
        return ShellResourceStore.ImageConversion(
            operation: operation,
            inputs: inputs,
            files: files,
            directory: directory
        )
    }

    mutating func endImageConversion() -> (waiters: [CheckedContinuation<Void, Never>], cancelled: Bool) {
        var waiters: [CheckedContinuation<Void, Never>] = []
        swap(&waiters, &conversionWaiters)
        conversion = .finished
        return (waiters, !operation.isActive)
    }

    mutating func cancelForCleanup() -> Bool {
        operation.cancel()
        if case .running = conversion { return false }
        return true
    }
}
