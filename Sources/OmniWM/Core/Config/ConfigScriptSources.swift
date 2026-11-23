// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Darwin
import Foundation
import OmniWMScriptHost

struct ConfigScriptSources {
    private struct Module {
        let logicalURL: URL
        let name: String
        let nameBytes: NSData
        let bytes: NSData
        let fingerprint: SettingsFileAccess.Fingerprint

        func descriptor(id: UInt32) -> omni_config_module {
            omni_config_module(id: id, name: Self.span(nameBytes), source: Self.span(bytes))
        }

        private static func span(_ data: NSData) -> omni_config_span {
            omni_config_span(data: data.bytes.assumingMemoryBound(to: CChar.self), length: data.length)
        }
    }

    let entry: URL?
    private(set) var versions: [URL: ConfigScriptFileVersion] = [:]
    private var modules: [Module] = []
    private var resolvedIDs: [URL: UInt32] = [:]
    private var logicalIDs: [URL: UInt32] = [:]
    private var totalBytes = 0

    var moduleCount: Int {
        modules.count
    }

    init(entry: URL?) {
        self.entry = entry
    }

    init(entry: URL?, sourceByteCount: Int) {
        self.entry = entry?.standardizedFileURL
        totalBytes = sourceByteCount
        if let entry = self.entry {
            logicalIDs[entry] = 0
            if let resolved = try? SettingsFileAccess.canonicalURL(for: entry) { resolvedIDs[resolved] = 0 }
        }
    }

    mutating func resolve(
        _ requester: UInt32, spec: omni_config_span, into result: UnsafeMutablePointer<omni_config_module>?,
        error: UnsafeMutablePointer<CChar>?, capacity: Int
    ) -> Bool {
        guard let result else { return false }
        do {
            result.pointee = try module(requestedBy: requester, spec: spec)
            return true
        } catch let failure {
            return failure.write(to: error, capacity: capacity)
        }
    }

    mutating func readEntry(at url: URL) throws -> Data? {
        let version = ConfigScriptFileVersion(at: url)
        versions[url] = version
        if case let .unresolved(link, error) = version, link == nil, error == Int(ENOENT) { return nil }
        let target = try SettingsFileAccess.settingsTarget(for: url)
        let resolved = try SettingsFileAccess.canonicalURL(for: target)
        let contents = try SettingsFileAccess.readContents(at: resolved, maximumBytes: ConfigScriptLoader.sourceLimit)
        versions[url] = .target(contents.fingerprint)
        logicalIDs[url] = 0
        resolvedIDs[resolved] = 0
        totalBytes = contents.data.count
        return contents.data
    }

    func name(of source: UInt32) -> String {
        source == 0 ? "init.luau" : modules[Int(source) - 1].name
    }

    mutating func module(
        requestedBy source: UInt32,
        spec: omni_config_span
    ) throws(ConfigScriptError) -> omni_config_module {
        guard let entry else { throw ConfigScriptError(line: nil, message: "require needs a file-backed config.") }
        let parent = source == 0 ? entry : modules[Int(source) - 1].logicalURL
        let url = try Self.moduleURL(spec: spec, importer: parent)
        do {
            let id: UInt32
            if let cached = logicalIDs[url] {
                id = cached
            } else {
                guard logicalIDs.count - 1 < Int(OMNI_CONFIG_MODULE_LIMIT) else {
                    throw ConfigScriptError(line: nil, message: "Config module limit exceeded.")
                }
                versions[url] = ConfigScriptFileVersion(at: url)
                id = try loadModule(url, entry: entry)
                logicalIDs[url] = id
            }
            if id == 0 {
                return omni_config_module(id: 0, name: spec, source: omni_config_span())
            }
            return modules[Int(id) - 1].descriptor(id: id)
        } catch let error as ConfigScriptError {
            throw error
        } catch {
            throw ConfigScriptError(line: nil, message: "Cannot load \(url.path): \(error.localizedDescription)")
        }
    }

    private static func moduleURL(spec: omni_config_span, importer: URL) throws(ConfigScriptError) -> URL {
        let bytes = UnsafeRawBufferPointer(start: spec.data, count: spec.length)
        guard let path = String(bytes: bytes, encoding: .utf8), !path.utf8.contains(0),
              path.hasPrefix("./") || path.hasPrefix("../"), !path.hasSuffix("/")
        else { throw ConfigScriptError(line: nil, message: "require expects a UTF-8 path beginning with ./ or ../.") }
        let component = (path as NSString).lastPathComponent
        guard component != ".", component != ".." else {
            throw ConfigScriptError(line: nil, message: "require expects a .luau module file.")
        }
        let suffix = (component as NSString).pathExtension
        guard suffix.isEmpty || suffix == "luau" else {
            throw ConfigScriptError(line: nil, message: "Only .luau modules can be required.")
        }
        let file = suffix.isEmpty ? path + ".luau" : path
        return importer.deletingLastPathComponent().appendingPathComponent(file, isDirectory: false).standardizedFileURL
    }

    private mutating func loadModule(_ url: URL, entry: URL) throws -> UInt32 {
        let target = try SettingsFileAccess.settingsTarget(for: url)
        let resolved = try SettingsFileAccess.canonicalURL(for: target)
        if let id = resolvedIDs[resolved] {
            versions[url] = id == 0 ? versions[entry] ?? ConfigScriptFileVersion(at: url) :
                .target(modules[Int(id) - 1].fingerprint)
            return id
        }
        let remaining = ConfigScriptLoader.sourceLimit - totalBytes
        let contents: SettingsFileAccess.Contents
        do {
            contents = try SettingsFileAccess.readContents(at: resolved, maximumBytes: remaining)
        } catch let error as POSIXError where error.code == .EFBIG {
            throw ConfigScriptError(line: nil, message: "Config sources exceed the 1 MiB limit at \(url.path).")
        }
        let directory = entry.deletingLastPathComponent().path
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        let name = url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.path
        let module = Module(
            logicalURL: url,
            name: name,
            nameBytes: Data(name.utf8) as NSData,
            bytes: contents.data as NSData,
            fingerprint: contents.fingerprint
        )
        modules.append(module)
        let id = UInt32(modules.count)
        versions[url] = .target(contents.fingerprint)
        resolvedIDs[resolved] = id
        totalBytes += contents.data.count
        return id
    }
}

extension ConfigScriptError {
    func write(
        to buffer: UnsafeMutablePointer<CChar>?,
        capacity: Int
    ) -> Bool {
        guard let buffer, capacity > 0 else { return false }
        let bytes = message.utf8
        var end = bytes.index(bytes.startIndex, offsetBy: capacity - 1, limitedBy: bytes.endIndex) ?? bytes.endIndex
        while end != bytes.startIndex, end != bytes.endIndex, bytes[end] & 0xC0 == 0x80 {
            bytes.formIndex(before: &end)
        }
        var count = 0
        for byte in bytes[..<end] {
            buffer[count] = CChar(bitPattern: byte)
            count += 1
        }
        buffer[count] = 0
        return false
    }
}
