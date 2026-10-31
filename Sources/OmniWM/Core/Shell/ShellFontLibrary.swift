// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreText
import Foundation
import OmniWMScriptHost
import Synchronization

struct ShellFontSet: Equatable, Sendable {
    var ids: [String: UInt8] = [:]
}

final class ShellFontLibrary: Sendable {
    private struct Scan {
        let fingerprint: SettingsFileAccess.Fingerprint?
        let families: [String]?
    }

    private struct Registry {
        var files: [URL: Scan] = [:]
        var owners: [String: UInt8] = [:]
        var exhausted = false
    }

    static let shared = ShellFontLibrary()
    static let fileLimit = 16
    static let byteLimit = 16 << 20
    private static let capacity = Int(OMNI_STYLE_FONT_MASK >> OMNI_STYLE_FONT_SHIFT) + 1 - Int(OMNI_STYLE_FONT_CUSTOM)
    private static let signatures: [[UInt8]] = [[0, 1, 0, 0], Array("true".utf8), Array("OTTO".utf8)]

    private let registry = Mutex(Registry())
    private let published = Mutex<[String]>([])

    static func folders(_ directories: [URL]) -> [URL] {
        directories.map { $0.appendingPathComponent("fonts", isDirectory: true) }
    }

    static func files(in folder: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return Array(entries
            .filter { ["ttf", "otf"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(fileLimit))
    }

    func fonts(in folders: [URL]) -> ShellFontSet {
        registry.withLock { registry in
            var set = ShellFontSet()
            for folder in folders {
                var unowned: [String: [URL]] = [:]
                for file in Self.files(in: folder).map(\.standardizedFileURL) {
                    let fingerprint = SettingsFileAccess.currentFingerprint(at: file)
                    let scan = registry.files[file].flatMap { $0.fingerprint == fingerprint ? $0 : nil }
                        ?? Scan(fingerprint: fingerprint, families: Self.families(of: file, in: folder))
                    registry.files[file] = scan
                    for family in scan.families ?? [] {
                        if let id = registry.owners[family] {
                            set.ids[family] = id
                        } else {
                            unowned[family, default: []].append(file)
                        }
                    }
                }
                for (family, files) in unowned.sorted(by: { $0.key < $1.key }) {
                    set.ids[family] = register(family, files, in: &registry)
                }
            }
            return set
        }
    }

    func family(of style: UInt32) -> String? {
        let index = Int((style & OMNI_STYLE_FONT_MASK) >> OMNI_STYLE_FONT_SHIFT) - Int(OMNI_STYLE_FONT_CUSTOM)
        guard index >= 0 else { return nil }
        return published.withLock { families in index < families.count ? families[index] : nil }
    }

    private func register(_ family: String, _ files: [URL], in registry: inout Registry) -> UInt8? {
        guard published.withLock({ $0.count }) < Self.capacity else {
            if !registry.exhausted {
                registry.exhausted = true
                Log.shell.error("Style fonts are limited to \(Self.capacity) families; \(family) uses the system font")
            }
            return nil
        }
        var registered = false
        for file in files {
            var error: Unmanaged<CFError>?
            let succeeded = CTFontManagerRegisterFontsForURL(
                file.resolvingSymlinksInPath().standardizedFileURL as CFURL, .process, &error
            )
            let code = error.map { CFErrorGetCode($0.takeRetainedValue()) }
            if succeeded || code == CTFontManagerError.alreadyRegistered.rawValue
                || code == CTFontManagerError.duplicatedName.rawValue
            {
                registered = true
            } else {
                registry.files[file] = Scan(fingerprint: registry.files[file]?.fingerprint, families: nil)
                Log.shell.error("Failed to load the style font \(file.path)")
            }
        }
        guard registered else { return nil }
        let id = published.withLock { families in
            families.append(family)
            return UInt8(Int(OMNI_STYLE_FONT_CUSTOM) + families.count - 1)
        }
        registry.owners[family] = id
        return id
    }

    private static func families(of listed: URL, in folder: URL) -> [String]? {
        let file = listed.resolvingSymlinksInPath().standardizedFileURL
        let problem = problem(with: file, in: folder)
        let descriptors = problem == nil
            ? CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor] ?? [] : []
        guard problem == nil, !descriptors.isEmpty else {
            Log.shell.error("Skipped the style font \(file.path): \(problem ?? "it could not be read")")
            return nil
        }
        let names = Set(descriptors
            .compactMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String })
        return names.sorted().filter { name in
            guard (1 ... Int(OMNI_FONT_NAME_LIMIT)).contains(name.utf8.count), !name.unicodeScalars.contains(where: {
                $0.value < 32 || $0.value == 127
            }) else {
                Log.shell.error("Skipped the style font \(file.path): its family name is invalid")
                return false
            }
            return true
        }
    }

    private static func problem(with file: URL, in folder: URL) -> String? {
        guard file.path.hasPrefix(folder.resolvingSymlinksInPath().standardizedFileURL.path + "/") else {
            return "it is outside its fonts folder"
        }
        let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else { return "it is not a regular file" }
        guard let size = values?.fileSize, size <= byteLimit else { return "it is larger than 16 MiB" }
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe), signatures.contains(Array(data.prefix(4)))
        else {
            return "it is not an uncompressed TrueType or OpenType font"
        }
        return nil
    }
}
