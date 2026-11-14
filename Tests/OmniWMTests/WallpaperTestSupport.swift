// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
@testable import OmniWM
import os

@MainActor
final class FakeWallpaperDesktop: WallpaperDesktop {
    var onChange: (@MainActor () -> Void)?
    var screens: [WallpaperDisplay]
    var events: [String] = []
    var revealed: [URL] = []
    var failing: Set<String> = []
    var unreadable: String?
    private let looks = OSAllocatedUnfairLock(initialState: 0)

    init(_ screens: [WallpaperDisplay]) {
        self.screens = screens
    }

    var reads: Int {
        looks.withLock { $0 }
    }

    func lookup() -> (screens: [WallpaperDisplay], shown: WallpaperShownLookup) {
        let screens = screens
        let (looks, unreadable) = (looks, unreadable)
        return (screens, {
            looks.withLock { $0 += 1 }
            if let unreadable { return .failure(WallpaperDesktopFailure(message: unreadable)) }
            return .success(screens.map { WallpaperShown(current: $0.current, thumbnail: $0.thumbnail, kind: $0.kind) })
        })
    }

    func setWallpaper(_ url: URL, on display: WallpaperDisplay, placement: WallpaperPlacement) throws {
        let matches = screens.indices.filter { index in
            if let uuid = display.uuid { return screens[index].uuid == uuid }
            return screens[index].displayId == display.displayId
        }
        guard matches.count == 1, let index = matches.first, !failing.contains(display.key) else {
            events.append("missing \(display.name)")
            throw WallpaperDesktopFailure(message: "\(display.name) is no longer connected")
        }
        screens[index].current = url
        events.append("set \(screens[index].key) \(url.lastPathComponent)")
    }

    func reveal(_ folder: URL) {
        revealed.append(folder)
    }

    func plug(_ display: WallpaperDisplay) {
        screens.append(display)
        onChange?()
    }

    func unplug(_ key: String) {
        screens.removeAll { $0.key == key }
        onChange?()
    }
}

@MainActor
final class FakeWallpaperPalette: WallpaperPaletteTarget {
    struct Refused: Error, LocalizedError {
        var errorDescription: String? {
            "the disk is full"
        }
    }

    var wallpaperPaletteState = WallpaperPaletteState(active: true, scheme: .tonalSpot)
    weak var desktop: FakeWallpaperDesktop?
    var published: [[UInt32]] = []
    var accepts = true
    var fails = false
    var refreshed = 0
    var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var arrivals: [CheckedContinuation<Void, Never>] = []

    func publishWallpaperPalette(_ pixels: [UInt32]) async throws -> Bool {
        published.append(pixels)
        desktop?.events.append("palette \(pixels.first ?? 0)")
        arrivals.forEach { $0.resume() }
        arrivals = []
        if holding { await withCheckedContinuation { held.append($0) } }
        if fails { throw Refused() }
        return accepts
    }

    func refreshWallpaperPalette() {
        refreshed += 1
    }

    func publishing() async {
        guard published.isEmpty else { return }
        await withCheckedContinuation { arrivals.append($0) }
    }

    func release() {
        holding = false
        held.forEach { $0.resume() }
        held = []
    }
}

@MainActor
final class WallpaperSampleGate {
    private var holding: Set<String>
    private var held: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var arrivals: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var returns: [String: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var requests: [String] = []
    private(set) var returned: [String] = []

    init(holding: Set<String> = []) {
        self.holding = holding
    }

    static func pixels(_ name: String) -> [UInt32] {
        [name.utf8.reduce(UInt32(0)) { $0 &* 31 &+ UInt32($1) }]
    }

    func sample(_ key: WallpaperSampleKey) async -> [UInt32]? {
        let name = URL(fileURLWithPath: key.file.path).lastPathComponent
        requests.append(name)
        arrivals.removeValue(forKey: name)?.forEach { $0.resume() }
        arrivals.removeValue(forKey: "")?.forEach { $0.resume() }
        if holding.contains(name) { await withCheckedContinuation { held[name, default: []].append($0) } }
        returned.append(name)
        returns.removeValue(forKey: name)?.forEach { $0.resume() }
        return Self.pixels(name)
    }

    func finished(_ name: String) async {
        guard !returned.contains(name) else { return }
        await withCheckedContinuation { returns[name, default: []].append($0) }
    }

    func requested(_ name: String? = nil) async {
        guard name.map({ !requests.contains($0) }) ?? requests.isEmpty else { return }
        await withCheckedContinuation { arrivals[name ?? "", default: []].append($0) }
    }

    func release(_ name: String? = nil) {
        if let name {
            holding.remove(name)
            held.removeValue(forKey: name)?.forEach { $0.resume() }
            return
        }
        holding = []
        held.values.joined().forEach { $0.resume() }
        held = [:]
    }
}

final class WallpaperHeldWork: Sendable {
    private let state = OSAllocatedUnfairLock<(
        held: [@Sendable () -> Void], waiting: [CheckedContinuation<Void, Never>]
    )>(initialState: ([], []))

    var count: Int {
        state.withLock { $0.held.count }
    }

    func perform(_ work: @escaping @Sendable () -> Void) {
        let waiting = state.withLock { state in
            state.held.append(work)
            defer { state.waiting = [] }
            return state.waiting
        }
        for waiter in waiting {
            waiter.resume()
        }
    }

    func queued() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                if state.held.isEmpty { state.waiting.append(continuation) }
                return !state.held.isEmpty
            }
            if ready { continuation.resume() }
        }
    }

    func release() {
        let work = state.withLock { state in
            defer { state.held.removeAll() }
            return state.held
        }
        for item in work {
            item()
        }
    }

    func releaseNewest() {
        let newest = state.withLock { $0.held.popLast() }
        newest?()
    }
}

final class WallpaperHeldHops: Sendable {
    private let held = OSAllocatedUnfairLock<[@MainActor @Sendable () -> Void]>(initialState: [])

    var count: Int {
        held.withLock { $0.count }
    }

    func deliver(_ work: @escaping @MainActor @Sendable () -> Void) {
        held.withLock { $0.append(work) }
    }

    @MainActor
    func release() {
        let work = held.withLock { held in
            defer { held.removeAll() }
            return held
        }
        for item in work {
            item()
        }
    }

    @MainActor
    func releaseNewest() {
        let newest = held.withLock { $0.popLast() }
        newest?()
    }
}

final class WallpaperStateBox: Sendable {
    struct Failure: Error, LocalizedError {
        var errorDescription: String? {
            "the volume is read-only"
        }
    }

    private let stored: OSAllocatedUnfairLock<(state: WallpaperRuntimeState, saves: Int, failing: Bool)>

    init(_ state: WallpaperRuntimeState = WallpaperRuntimeState()) {
        stored = OSAllocatedUnfairLock(initialState: (state, 0, false))
    }

    var state: WallpaperRuntimeState {
        get { stored.withLock { $0.state } }
        set { stored.withLock { $0.state = newValue } }
    }

    var saves: Int {
        stored.withLock { $0.saves }
    }

    var failing: Bool {
        get { stored.withLock { $0.failing } }
        set { stored.withLock { $0.failing = newValue } }
    }

    func load() -> WallpaperRuntimeState {
        state
    }

    func save(_ next: WallpaperRuntimeState) throws {
        try stored.withLock { stored in
            guard !stored.failing else { throw Failure() }
            stored.state = next
            stored.saves += 1
        }
    }
}

final class WallpaperCounter: Sendable {
    private let counted = OSAllocatedUnfairLock<[String]>(initialState: [])

    var values: [String] {
        counted.withLock { $0 }
    }

    func add(_ value: String) {
        counted.withLock { $0.append(value) }
    }
}

@MainActor
final class ManualWallpaperClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var timers: [(due: Date, action: @MainActor () -> Void, cancelled: Bool)] = []

    func schedule(_ due: Date, _ action: @escaping @MainActor () -> Void) -> (@MainActor () -> Void) {
        let index = timers.count
        timers.append((due, action, false))
        return { [weak self] in self?.timers[index].cancelled = true }
    }

    var pending: [Date] {
        timers.filter { !$0.cancelled }.map(\.due)
    }

    func advance(to date: Date) {
        now = date
        for index in timers.indices where !timers[index].cancelled && timers[index].due <= date {
            timers[index].cancelled = true
            timers[index].action()
        }
    }
}

enum WallpaperFixtures {
    static let macBook = WallpaperDisplay(
        displayId: 1, uuid: "11111111-1111-1111-1111-111111111111", name: "Built-in Retina Display",
        size: CGSize(width: 1512, height: 982), isMain: true, isBuiltin: true, hasNotch: true
    )
    static let studio = WallpaperDisplay(
        displayId: 2, uuid: "22222222-2222-2222-2222-222222222222", name: "Studio Display",
        size: CGSize(width: 2560, height: 1440), isMain: true
    )
    static let twinLeft = WallpaperDisplay(
        displayId: 3, uuid: "33333333-3333-3333-3333-333333333333", name: "DELL U2723QE",
        size: CGSize(width: 2560, height: 1440), isMain: true
    )
    static let twinRight = WallpaperDisplay(
        displayId: 4, uuid: "44444444-4444-4444-4444-444444444444", name: "DELL U2723QE",
        size: CGSize(width: 2560, height: 1440), isMain: false
    )

    static func secondary(_ display: WallpaperDisplay) -> WallpaperDisplay {
        WallpaperDisplay(
            displayId: display.displayId, uuid: display.uuid, name: display.name, size: display.size, isMain: false,
            isBuiltin: display.isBuiltin, hasNotch: display.hasNotch, current: display.current
        )
    }

    static func makeFolder(_ root: URL, _ name: String, files: [String]) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files {
            try Data(file.utf8).write(to: folder.appendingPathComponent(file))
        }
        return folder
    }

    static func environment(
        state: WallpaperStateBox, home: String, synchronous: Bool = true
    ) -> WallpaperEnvironment {
        var environment = WallpaperEnvironment(stateFile: URL(fileURLWithPath: home).appendingPathComponent("state"))
        environment.home = home
        environment.loadState = { state.load() }
        environment.saveState = { try state.save($0) }
        environment.schedule = { _, _ in {} }
        environment.preview = { _ in nil }
        if synchronous {
            environment.perform = { $0() }
            environment.deliver = { MainActor.assumeIsolated($0) }
        }
        return environment
    }

    static func writeImage(_ url: URL, width: Int, height: Int, color: (CGFloat, CGFloat, CGFloat)) throws {
        let context = try XCTUnwrapContext(width: width, height: height)
        context.setFillColor(CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }

    private static func XCTUnwrapContext(width: Int, height: Int) throws -> CGContext {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }
        return context
    }
}
