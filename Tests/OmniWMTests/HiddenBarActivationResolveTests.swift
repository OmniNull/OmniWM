// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class HiddenBarActivationResolveTests: XCTestCase {
    private let bundleID = "com.example.status"

    private func key(_ ordinal: Int) -> MenuBarItemKey {
        MenuBarItemKey(bundleID: bundleID, ordinal: ordinal)
    }

    private func identity(_ value: String) -> MenuBarItemSemanticIdentity {
        MenuBarItemSemanticIdentity(
            identifier: value,
            title: nil,
            accessibilityDescription: nil,
            help: nil
        )
    }

    private func item(
        ordinal: Int,
        pid: pid_t = 1234,
        identity: MenuBarItemSemanticIdentity? = nil
    ) -> ResolvedMenuBarItem {
        ResolvedMenuBarItem(
            key: key(ordinal),
            pid: pid,
            bounds: CGRect(x: CGFloat(ordinal) * 30, y: 0, width: 24, height: 24),
            semanticIdentity: identity
        )
    }

    private func icon(red: CGFloat, green: CGFloat = 0) -> CapturedIcon {
        let context = CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: red, green: green, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return CapturedIcon(image: context.makeImage()!, scale: 2)
    }

    func testMissingCachedIdentityRejectsActivation() {
        XCTAssertNil(HiddenBarActivationPolicy.activationTarget(
            for: key(0),
            cachedItems: nil,
            cachedIcons: [:],
            freshItems: [item(ordinal: 0, identity: identity("a"))],
            freshIcons: [:]
        ))
    }

    func testAuthoritativeEmptyResolutionRejectsActivation() {
        XCTAssertNil(HiddenBarActivationPolicy.activationTarget(
            for: key(0),
            cachedItems: [item(ordinal: 0, identity: identity("a"))],
            cachedIcons: [:],
            freshItems: [],
            freshIcons: [:]
        ))
    }

    func testAuthoritativeEmptyRequiresResolutionDeadlineGrace() {
        XCTAssertFalse(MenuBarItemSampleTracker.shouldAcceptAuthoritativeEmpty(
            continuouslyEmptyFor: .milliseconds(50)
        ))
        XCTAssertFalse(MenuBarItemSampleTracker.shouldAcceptAuthoritativeEmpty(
            continuouslyEmptyFor: .milliseconds(1999)
        ))
        XCTAssertTrue(MenuBarItemSampleTracker.shouldAcceptAuthoritativeEmpty(
            continuouslyEmptyFor: .seconds(2)
        ))
    }

    func testSemanticIdentitySurvivesInsertionBeforeItem() {
        let a = identity("a")
        let cached = [item(ordinal: 0, identity: a), item(ordinal: 1, identity: identity("b"))]
        let fresh = [
            item(ordinal: 0, identity: identity("inserted")),
            item(ordinal: 1, identity: a),
            item(ordinal: 2, identity: identity("b"))
        ]

        XCTAssertEqual(
            HiddenBarActivationPolicy.activationTarget(
                for: key(0),
                cachedItems: cached,
                cachedIcons: [:],
                freshItems: fresh,
                freshIcons: [:]
            )?.key,
            key(1)
        )
    }

    func testSemanticIdentitySurvivesDeletionBeforeItem() {
        let b = identity("b")
        let cached = [item(ordinal: 0, identity: identity("a")), item(ordinal: 1, identity: b)]
        let fresh = [item(ordinal: 0, identity: b)]

        XCTAssertEqual(
            HiddenBarActivationPolicy.activationTarget(
                for: key(1),
                cachedItems: cached,
                cachedIcons: [:],
                freshItems: fresh,
                freshIcons: [:]
            )?.key,
            key(0)
        )
    }

    func testSemanticIdentitySurvivesReorder() {
        let a = identity("a")
        let cached = [item(ordinal: 0, identity: a), item(ordinal: 1, identity: identity("b"))]
        let fresh = [item(ordinal: 0, identity: identity("b")), item(ordinal: 1, identity: a)]

        XCTAssertEqual(
            HiddenBarActivationPolicy.activationTarget(
                for: key(0),
                cachedItems: cached,
                cachedIcons: [:],
                freshItems: fresh,
                freshIcons: [:]
            )?.key,
            key(1)
        )
    }

    func testDuplicateSemanticIdentityRejectsAmbiguousActivation() {
        let duplicate = identity("duplicate")
        XCTAssertNil(HiddenBarActivationPolicy.activationTarget(
            for: key(0),
            cachedItems: [item(ordinal: 0, identity: duplicate)],
            cachedIcons: [:],
            freshItems: [
                item(ordinal: 0, identity: duplicate),
                item(ordinal: 1, identity: duplicate)
            ],
            freshIcons: [:]
        ))
    }

    func testDuplicateCachedSemanticIdentityRejectsAmbiguousActivation() {
        let duplicate = identity("duplicate")
        XCTAssertNil(HiddenBarActivationPolicy.activationTarget(
            for: key(0),
            cachedItems: [
                item(ordinal: 0, identity: duplicate),
                item(ordinal: 1, identity: duplicate)
            ],
            cachedIcons: [:],
            freshItems: [item(ordinal: 0, identity: duplicate)],
            freshIcons: [:]
        ))
    }

    func testSemanticMismatchDoesNotFallBackToMatchingPixels() {
        let red = icon(red: 1)
        XCTAssertNil(HiddenBarActivationPolicy.activationTarget(
            for: key(0),
            cachedItems: [item(ordinal: 0, identity: identity("cached"))],
            cachedIcons: [key(0): red],
            freshItems: [item(ordinal: 0, identity: identity("fresh"))],
            freshIcons: [key(0): icon(red: 1)]
        ))
    }

    func testPixelIdentitySurvivesReorderWithoutAXIdentity() {
        let red = icon(red: 1)
        let green = icon(red: 0, green: 1)
        let cached = [item(ordinal: 0), item(ordinal: 1)]
        let fresh = [item(ordinal: 0), item(ordinal: 1)]

        XCTAssertEqual(
            HiddenBarActivationPolicy.activationTarget(
                for: key(0),
                cachedItems: cached,
                cachedIcons: [key(0): red, key(1): green],
                freshItems: fresh,
                freshIcons: [key(0): green, key(1): red]
            )?.key,
            key(1)
        )
    }

    func testSoleUnnamedItemSurvivesChangedPixelsAndUsesFreshBounds() {
        let fresh = ResolvedMenuBarItem(
            key: key(0), pid: 1234,
            bounds: CGRect(x: 500, y: 3, width: 36, height: 24)
        )
        let target = HiddenBarActivationPolicy.activationTarget(
            for: key(0),
            cachedItems: [item(ordinal: 0)],
            cachedIcons: [key(0): icon(red: 1)],
            freshItems: [fresh],
            freshIcons: [key(0): icon(red: 0, green: 1)]
        )

        XCTAssertEqual(target?.bounds, fresh.bounds)
        XCTAssertEqual(target?.pid, fresh.pid)
    }

    func testSoleUnnamedItemSurvivesMissingCapturedPixels() {
        let captured = [key(0): icon(red: 1)]
        let snapshots: [([MenuBarItemKey: CapturedIcon], [MenuBarItemKey: CapturedIcon])] = [
            (captured, [:]), ([:], captured), ([:], [:])
        ]
        for (cachedIcons, freshIcons) in snapshots {
            XCTAssertEqual(HiddenBarActivationPolicy.activationTarget(
                for: key(0),
                cachedItems: [item(ordinal: 0)],
                cachedIcons: cachedIcons,
                freshItems: [item(ordinal: 0)],
                freshIcons: freshIcons
            )?.key, key(0))
        }
    }

    func testSoleUnnamedItemRejectsChangedProcess() {
        XCTAssertNil(HiddenBarActivationPolicy.activationTarget(
            for: key(0),
            cachedItems: [item(ordinal: 0)],
            cachedIcons: [:],
            freshItems: [item(ordinal: 0, pid: 5678)],
            freshIcons: [:]
        ))
    }

    func testSoleUnnamedItemDoesNotIgnoreNewSemanticIdentity() {
        XCTAssertNil(HiddenBarActivationPolicy.activationTarget(
            for: key(0),
            cachedItems: [item(ordinal: 0)],
            cachedIcons: [:],
            freshItems: [item(ordinal: 0, identity: identity("new"))],
            freshIcons: [:]
        ))
    }

    func testMultipleUnnamedItemsStillRequirePixelIdentity() {
        let one = [item(ordinal: 0)]
        let two = [item(ordinal: 0), item(ordinal: 1)]
        for (cached, fresh) in [(one, two), (two, one), (two, two)] {
            XCTAssertNil(HiddenBarActivationPolicy.activationTarget(
                for: key(0),
                cachedItems: cached,
                cachedIcons: [:],
                freshItems: fresh,
                freshIcons: [:]
            ))
        }
    }

    func testDuplicatePixelIdentityRejectsAmbiguousActivation() {
        let red = icon(red: 1)
        XCTAssertNil(HiddenBarActivationPolicy.activationTarget(
            for: key(0),
            cachedItems: [item(ordinal: 0)],
            cachedIcons: [key(0): red],
            freshItems: [item(ordinal: 0), item(ordinal: 1)],
            freshIcons: [key(0): icon(red: 1), key(1): icon(red: 1)]
        ))
    }

    func testDuplicateCachedPixelIdentityRejectsAmbiguousActivation() {
        let red = icon(red: 1)
        XCTAssertNil(HiddenBarActivationPolicy.activationTarget(
            for: key(0),
            cachedItems: [item(ordinal: 0), item(ordinal: 1)],
            cachedIcons: [key(0): red, key(1): icon(red: 1)],
            freshItems: [item(ordinal: 0)],
            freshIcons: [key(0): icon(red: 1)]
        ))
    }

    func testIncompletePixelSnapshotRejectsActivation() {
        let red = icon(red: 1)
        XCTAssertNil(HiddenBarActivationPolicy.activationTarget(
            for: key(0),
            cachedItems: [item(ordinal: 0), item(ordinal: 1)],
            cachedIcons: [key(0): red],
            freshItems: [item(ordinal: 0), item(ordinal: 1)],
            freshIcons: [key(0): icon(red: 1), key(1): icon(red: 0, green: 1)]
        ))
    }

    func testChangedProcessRejectsActivation() {
        let stableIdentity = identity("a")
        XCTAssertNil(HiddenBarActivationPolicy.activationTarget(
            for: key(0),
            cachedItems: [item(ordinal: 0, identity: stableIdentity)],
            cachedIcons: [:],
            freshItems: [item(ordinal: 0, pid: 5678, identity: stableIdentity)],
            freshIcons: [:]
        ))
    }

    func testActivationOwnerPrefersSelectedCachedPIDAcrossMultipleProcesses() {
        let selected = item(ordinal: 0, pid: 42)
        XCTAssertEqual(
            HiddenBarActivationPolicy.activationOwner(
                bundleID: bundleID,
                selectedItem: selected,
                cachedItems: [selected],
                runningCandidates: [
                    MenuBarAppCandidate(bundleID: bundleID, pid: 41),
                    MenuBarAppCandidate(bundleID: bundleID, pid: 42)
                ]
            ),
            HiddenBarActivationOwner(pid: 42, allowsAuthoritativeEmpty: true)
        )
    }

    func testActivationOwnerRejectsAmbiguousUncachedProcesses() {
        XCTAssertNil(HiddenBarActivationPolicy.activationOwner(
            bundleID: bundleID,
            selectedItem: nil,
            cachedItems: nil,
            runningCandidates: [
                MenuBarAppCandidate(bundleID: bundleID, pid: 41),
                MenuBarAppCandidate(bundleID: bundleID, pid: 42)
            ]
        ))
    }

    func testActivationOwnerUsesKnownBundlePIDWhenSelectedItemIsMissing() {
        XCTAssertEqual(
            HiddenBarActivationPolicy.activationOwner(
                bundleID: bundleID,
                selectedItem: nil,
                cachedItems: [item(ordinal: 1, pid: 42)],
                runningCandidates: [
                    MenuBarAppCandidate(bundleID: bundleID, pid: 41),
                    MenuBarAppCandidate(bundleID: bundleID, pid: 42)
                ]
            ),
            HiddenBarActivationOwner(pid: 42, allowsAuthoritativeEmpty: true)
        )
    }

    func testSoleUncachedProcessCannotAuthoritativelyClearItems() {
        XCTAssertEqual(
            HiddenBarActivationPolicy.activationOwner(
                bundleID: bundleID,
                selectedItem: nil,
                cachedItems: nil,
                runningCandidates: [
                    MenuBarAppCandidate(bundleID: bundleID, pid: 41)
                ]
            ),
            HiddenBarActivationOwner(pid: 41, allowsAuthoritativeEmpty: false)
        )
    }

    func testStaleCachedOwnerDoesNotFallBackToAnotherProcess() {
        XCTAssertNil(HiddenBarActivationPolicy.activationOwner(
            bundleID: bundleID,
            selectedItem: nil,
            cachedItems: [item(ordinal: 0, pid: 42)],
            runningCandidates: [
                MenuBarAppCandidate(bundleID: bundleID, pid: 41)
            ]
        ))
    }

    func testActivationResolveHealsCachedOrdinals() {
        let cache = HiddenBarIconCache()
        cache.replaceResolvedItems([bundleID: [item(ordinal: 0), item(ordinal: 1), item(ordinal: 2)]])
        XCTAssertEqual(cache.resolvedItems(for: bundleID)?.count, 3)

        cache.replaceResolvedItems([bundleID: [item(ordinal: 0), item(ordinal: 1)]])

        let healed = cache.resolvedItems(for: bundleID)
        XCTAssertEqual(healed?.map(\.key.ordinal), [0, 1])
    }
}
