// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices

struct DockBadgeReadResult: Sendable, Equatable {
    var labels: [String: String] = [:]
    var clearedBundleIDs: Set<String> = []
    var dockPID: pid_t?
}

actor DockBadgeReader {
    typealias AttributeReader = @Sendable (AXUIElement, CFString) -> (AXError, CFTypeRef?)

    private enum ReadError: Error {
        case ax(AXError)
        case invalidResponse
        case cancelled
    }

    private nonisolated let queue = DispatchSerialQueue(
        label: "com.barut.OmniWM.dock-badges",
        qos: .utility
    )

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    private let processIdentifier: @Sendable () -> pid_t?
    private let readAttribute: AttributeReader
    private let bundleIdentifier: @Sendable (URL) -> String?
    private var generation: UInt64 = 0
    private var dockPID: pid_t?
    private var elements: [String: AXUIElement] = [:]
    private var targetBundleIDs: Set<String> = []
    private var bundleIDsByURL: [URL: String] = [:]

    init(
        processIdentifier: @escaping @Sendable () -> pid_t? = {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
                .first?.processIdentifier
        },
        readAttribute: @escaping AttributeReader = { element, attribute in
            let timeoutResult = AXUIElementSetMessagingTimeout(element, 0.1)
            guard timeoutResult == .success else { return (timeoutResult, nil) }
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, attribute, &value)
            return (result, value)
        },
        bundleIdentifier: @escaping @Sendable (URL) -> String? = { Bundle(url: $0)?.bundleIdentifier }
    ) {
        self.processIdentifier = processIdentifier
        self.readAttribute = readAttribute
        self.bundleIdentifier = bundleIdentifier
    }

    func reset(generation: UInt64) {
        guard generation >= self.generation else { return }
        self.generation = generation
        dockPID = nil
        elements.removeAll()
        targetBundleIDs.removeAll()
        bundleIDsByURL.removeAll()
    }

    func read(bundleIDs: Set<String>, generation: UInt64) -> DockBadgeReadResult {
        guard generation >= self.generation, !Task.isCancelled else { return DockBadgeReadResult() }
        if generation != self.generation {
            reset(generation: generation)
        }
        let pid = processIdentifier()
        if dockPID != pid {
            reset(generation: generation)
            dockPID = pid
        }
        var result = DockBadgeReadResult(dockPID: pid)
        guard let pid, !bundleIDs.isEmpty else { return result }
        if bundleIDs != targetBundleIDs {
            elements = elements.filter { bundleIDs.contains($0.key) }
            targetBundleIDs = bundleIDs
        }

        do {
            let needsScan = bundleIDs.contains { elements[$0] == nil }
            if needsScan {
                result.clearedBundleIDs = try scan(pid: pid, bundleIDs: bundleIDs)
            }
            let invalidBundleIDs = try readLabels(bundleIDs: bundleIDs, result: &result)
            if !invalidBundleIDs.isEmpty, !needsScan {
                result.clearedBundleIDs.formUnion(try scan(pid: pid, bundleIDs: bundleIDs))
                _ = try readLabels(bundleIDs: invalidBundleIDs, result: &result)
            }
        } catch {
            return result
        }
        return result
    }

    private func readLabels(
        bundleIDs: Set<String>,
        result: inout DockBadgeReadResult
    ) throws -> Set<String> {
        var invalidBundleIDs: Set<String> = []
        for bundleID in bundleIDs {
            guard let element = elements[bundleID] else { continue }
            do {
                let value = try attribute("AXStatusLabel", of: element)
                guard let value else {
                    result.clearedBundleIDs.insert(bundleID)
                    continue
                }
                guard let label = value as? String else { continue }
                if label.isEmpty {
                    result.clearedBundleIDs.insert(bundleID)
                } else {
                    result.labels[bundleID] = label
                }
            } catch ReadError.ax(.invalidUIElement) {
                elements.removeValue(forKey: bundleID)
                invalidBundleIDs.insert(bundleID)
            } catch {
                try stopIfUnavailable(error)
            }
        }
        return invalidBundleIDs
    }

    private func scan(pid: pid_t, bundleIDs: Set<String>) throws -> Set<String> {
        let root = AXUIElementCreateApplication(pid)
        let rootChildren = try children(of: root)
        var foundList = false
        var complete = true
        var discovered: [String: AXUIElement] = [:]
        for child in rootChildren {
            do {
                guard let role = try attribute(kAXRoleAttribute, of: child) as? String else {
                    throw ReadError.invalidResponse
                }
                guard role == kAXListRole else { continue }
                foundList = true
                for tile in try children(of: child) {
                    do {
                        if let bundleID = try applicationBundleID(of: tile), bundleIDs.contains(bundleID) {
                            discovered[bundleID] = tile
                        }
                    } catch {
                        complete = false
                        try stopIfUnavailable(error)
                    }
                }
            } catch {
                complete = false
                try stopIfUnavailable(error)
            }
        }
        if foundList, complete {
            elements = discovered
            return bundleIDs.subtracting(discovered.keys)
        } else {
            elements.merge(discovered) { _, new in new }
            return []
        }
    }

    private func applicationBundleID(of element: AXUIElement) throws -> String? {
        guard let subrole = try attribute(kAXSubroleAttribute, of: element) as? String else {
            throw ReadError.invalidResponse
        }
        guard subrole == "AXApplicationDockItem" else { return nil }
        let value = try attribute(kAXURLAttribute, of: element)
        let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
        guard let url else { throw ReadError.invalidResponse }
        if let bundleID = bundleIDsByURL[url] { return bundleID }
        guard let bundleID = bundleIdentifier(url)?.lowercased() else { throw ReadError.invalidResponse }
        bundleIDsByURL[url] = bundleID
        return bundleID
    }

    private func children(of element: AXUIElement) throws -> [AXUIElement] {
        guard let children = try attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] else {
            throw ReadError.invalidResponse
        }
        return children
    }

    private func attribute(_ name: String, of element: AXUIElement) throws -> CFTypeRef? {
        guard !Task.isCancelled else { throw ReadError.cancelled }
        let (error, value) = readAttribute(element, name as CFString)
        switch error {
        case .success:
            return value
        case .noValue,
             .attributeUnsupported:
            return nil
        default:
            throw ReadError.ax(error)
        }
    }

    private func stopIfUnavailable(_ error: Error) throws {
        switch error {
        case ReadError.ax(.cannotComplete),
             ReadError.cancelled:
            throw error
        default:
            break
        }
    }
}
