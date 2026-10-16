// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
@testable import OmniWM
import XCTest

private func menuAXErrorValue(_ error: AXError) -> AXValue? {
    var error = error
    return AXValueCreate(.axError, &error)
}

@MainActor
private final class MenuExtractorTarget: NSObject, NSMenuDelegate {
    @objc func activate(_: NSMenuItem) {}
}

@MainActor
final class MenuExtractorTests: XCTestCase {
    func testMenuRootAssociationRetainsIdentityAndClears() throws {
        let menu = NSMenu(title: "Submenu")
        let element = AXUIElementCreateApplication(91_579)
        XCTAssertNil(menu.axRootElement)

        menu.axRootElement = element

        XCTAssertTrue(try XCTUnwrap(menu.axRootElement) === element)

        menu.axRootElement = nil

        XCTAssertNil(menu.axRootElement)
    }

    func testNestedMenuConstructionDisablesAutomaticEnabling() throws {
        let itemElement = AXUIElementCreateApplication(91_510)
        let submenuRoot = AXUIElementCreateApplication(91_511)
        let target = MenuExtractorTarget()
        let snapshot = MenuItemSnapshot(
            element: itemElement,
            attributes: [
                "AXTitle": "Nested",
                "AXRole": "AXMenuItem",
                "AXEnabled": false
            ],
            submenuRoot: submenuRoot
        )
        let extractor = MenuExtractor()

        let items = extractor.makeSubmenuItems(
            from: [snapshot],
            target: target,
            action: #selector(MenuExtractorTarget.activate(_:))
        )
        let submenu = try XCTUnwrap(items.first?.submenu)

        XCTAssertFalse(submenu.autoenablesItems)
        XCTAssertTrue(submenu.delegate === target)
        XCTAssertTrue(submenu.axRootElement.map { CFEqual($0, submenuRoot) } == true)
        XCTAssertFalse(items[0].isEnabled)
        XCTAssertNotEqual(items[0].action, #selector(MenuExtractorTarget.activate(_:)))
    }

    func testEmptyChildrenAndUnavailableChildrenAreDistinct() throws {
        let root = AXUIElementCreateApplication(91_520)
        let emptyExtractor = MenuExtractor(
            environment: MenuExtractorEnvironment(
                now: { 0 },
                readAttribute: { _, _, _ in [AXUIElement]() },
                readAttributes: { _, _, _ in
                    XCTFail("Empty children should not trigger item reads")
                    return []
                }
            )
        )

        let emptyItems = try emptyExtractor.buildSubmenu(from: root, target: nil, action: nil)
        XCTAssertTrue(emptyItems.isEmpty)

        let unavailableExtractor = MenuExtractor(
            environment: MenuExtractorEnvironment(
                now: { 0 },
                readAttribute: { _, _, _ in throw MenuExtractionError.ax(.cannotComplete) },
                readAttributes: { _, _, _ in [] }
            )
        )

        XCTAssertThrowsError(
            try unavailableExtractor.buildSubmenu(from: root, target: nil, action: nil)
        ) { error in
            XCTAssertEqual(error as? MenuExtractionError, .ax(.cannotComplete))
        }
    }

    func testSubmenuSnapshotAbortsWhenSecondItemReadFails() {
        let root = AXUIElementCreateApplication(91_530)
        let first = AXUIElementCreateApplication(91_531)
        let second = AXUIElementCreateApplication(91_532)
        let extractor = MenuExtractor(
            environment: MenuExtractorEnvironment(
                now: { 0 },
                readAttribute: { _, _, _ in [first, second] },
                readAttributes: { element, attributes, _ in
                    if CFEqual(element, first) {
                        return self.attributeValues(
                            attributes,
                            values: [
                                "AXTitle": "First",
                                "AXRole": "AXMenuItem",
                                "AXEnabled": true
                            ]
                        )
                    }
                    throw MenuExtractionError.ax(.cannotComplete)
                }
            )
        )

        XCTAssertThrowsError(
            try extractor.buildSubmenu(from: root, target: nil, action: nil)
        ) { error in
            XCTAssertEqual(error as? MenuExtractionError, .ax(.cannotComplete))
        }
    }

    func testMissingEnabledEvidenceCreatesDisabledNonActionableItem() throws {
        let root = AXUIElementCreateApplication(91_540)
        let child = AXUIElementCreateApplication(91_541)
        let target = MenuExtractorTarget()
        let extractor = MenuExtractor(
            environment: MenuExtractorEnvironment(
                now: { 0 },
                readAttribute: { _, _, _ in [child] },
                readAttributes: { _, attributes, _ in
                    self.attributeValues(
                        attributes,
                        values: ["AXTitle": "Missing enabled", "AXRole": "AXMenuItem"]
                    )
                }
            )
        )

        let items = try extractor.buildSubmenu(
            from: root,
            target: target,
            action: #selector(MenuExtractorTarget.activate(_:))
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(items[0].isEnabled)
        XCTAssertNil(items[0].target)
        XCTAssertNil(items[0].action)
    }

    func testUnavailableNestedRoleDoesNotBecomeActionableLeaf() {
        let root = AXUIElementCreateApplication(91_550)
        let child = AXUIElementCreateApplication(91_551)
        let submenuRoot = AXUIElementCreateApplication(91_552)
        let extractor = MenuExtractor(
            environment: MenuExtractorEnvironment(
                now: { 0 },
                readAttribute: { element, _, _ in
                    if CFEqual(element, root) { return [child] }
                    throw MenuExtractionError.ax(.cannotComplete)
                },
                readAttributes: { _, attributes, _ in
                    self.attributeValues(
                        attributes,
                        values: [
                            "AXTitle": "Nested",
                            "AXRole": "AXMenuItem",
                            "AXEnabled": true,
                            "AXChildren": [submenuRoot]
                        ]
                    )
                }
            )
        )

        XCTAssertThrowsError(
            try extractor.buildSubmenu(from: root, target: nil, action: nil)
        ) { error in
            XCTAssertEqual(error as? MenuExtractionError, .ax(.cannotComplete))
        }
    }

    func testMissingRequiredRoleFailsSnapshot() {
        let root = AXUIElementCreateApplication(91_560)
        let child = AXUIElementCreateApplication(91_561)
        let extractor = MenuExtractor(
            environment: MenuExtractorEnvironment(
                now: { 0 },
                readAttribute: { _, _, _ in [child] },
                readAttributes: { _, attributes, _ in
                    self.attributeValues(attributes, values: ["AXTitle": "Missing role"])
                }
            )
        )

        XCTAssertThrowsError(
            try extractor.buildSubmenu(from: root, target: nil, action: nil)
        ) { error in
            XCTAssertEqual(error as? MenuExtractionError, .invalidResponse)
        }
    }

    func testEmptyTitledMenuItemBuildsSeparator() throws {
        let root = AXUIElementCreateApplication(91_562)
        let child = AXUIElementCreateApplication(91_563)
        let extractor = MenuExtractor(
            environment: MenuExtractorEnvironment(
                now: { 0 },
                readAttribute: { _, _, _ in [child] },
                readAttributes: { _, attributes, _ in
                    self.attributeValues(
                        attributes,
                        values: [
                            "AXTitle": "",
                            "AXRole": "AXMenuItem",
                            "AXEnabled": false
                        ]
                    )
                }
            )
        )

        let items = try extractor.buildSubmenu(from: root, target: nil, action: nil)

        XCTAssertTrue(items.isEmpty)
    }

    func testDecoderOmitsNullNoValueAndUnsupportedSlots() throws {
        let decoded = try MenuAXReader.decodeAttributeValues(
            names: ["title", "null", "missing", "unsupported"],
            values: [
                "Visible",
                kCFNull as Any,
                try XCTUnwrap(menuAXErrorValue(.noValue)),
                try XCTUnwrap(menuAXErrorValue(.attributeUnsupported))
            ]
        )

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded["title"] as? String, "Visible")
    }

    func testDecoderRejectsTransientAXErrors() throws {
        for axError in [AXError.cannotComplete, .invalidUIElement, .failure] {
            let value = try XCTUnwrap(menuAXErrorValue(axError))

            XCTAssertThrowsError(
                try MenuAXReader.decodeAttributeValues(names: ["value"], values: [value])
            ) { error in
                XCTAssertEqual(error as? MenuExtractionError, .ax(axError))
            }
        }
    }

    func testDecoderRejectsMismatchedValueCount() {
        XCTAssertThrowsError(
            try MenuAXReader.decodeAttributeValues(names: ["one", "two"], values: ["value"])
        ) { error in
            XCTAssertEqual(error as? MenuExtractionError, .invalidResponse)
        }
    }

    func testSubmenuReadsReceiveOneShrinkingDeadlineBudget() throws {
        let root = AXUIElementCreateApplication(91_570)
        let child = AXUIElementCreateApplication(91_571)
        var now: TimeInterval = 10
        var timeouts: [Float] = []
        let extractor = MenuExtractor(
            environment: MenuExtractorEnvironment(
                now: { now },
                readAttribute: { _, _, timeout in
                    timeouts.append(timeout)
                    now += 0.1
                    return [child]
                },
                readAttributes: { _, attributes, timeout in
                    timeouts.append(timeout)
                    now += 0.05
                    return self.attributeValues(
                        attributes,
                        values: [
                            "AXTitle": "Timed",
                            "AXRole": "AXMenuItem",
                            "AXEnabled": true
                        ]
                    )
                }
            ),
            submenuTimeout: 0.25
        )

        let items = try extractor.buildSubmenu(from: root, target: nil, action: nil)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(timeouts.count, 2)
        XCTAssertEqual(timeouts[0], 0.25, accuracy: 0.001)
        XCTAssertEqual(timeouts[1], 0.15, accuracy: 0.001)
    }

    func testExpiredDeadlineSkipsNextAXRead() {
        let root = AXUIElementCreateApplication(91_580)
        let child = AXUIElementCreateApplication(91_581)
        var now: TimeInterval = 0
        var attributeReadCount = 0
        let extractor = MenuExtractor(
            environment: MenuExtractorEnvironment(
                now: { now },
                readAttribute: { _, _, _ in
                    now = 0.25
                    return [child]
                },
                readAttributes: { _, _, _ in
                    attributeReadCount += 1
                    return []
                }
            ),
            submenuTimeout: 0.25
        )

        XCTAssertThrowsError(
            try extractor.buildSubmenu(from: root, target: nil, action: nil)
        ) { error in
            XCTAssertEqual(error as? MenuExtractionError, .deadlineExceeded)
        }
        XCTAssertEqual(attributeReadCount, 0)
    }

    func testMessagingTimeoutResetsExactElementWhenOperationThrows() {
        enum ProbeError: Error {
            case expected
        }

        let element = AXUIElementCreateApplication(91_590)
        var elements: [AXUIElement] = []
        var timeouts: [Float] = []

        XCTAssertThrowsError(
            try MenuAXReader.withMessagingTimeout(
                on: element,
                timeout: 0.25,
                setter: { configuredElement, timeout in
                    elements.append(configuredElement)
                    timeouts.append(timeout)
                    return .success
                }
            ) {
                throw ProbeError.expected
            }
        )

        XCTAssertEqual(timeouts, [0.25, 0])
        XCTAssertEqual(elements.count, 2)
        XCTAssertTrue(elements.allSatisfy { CFEqual($0, element) })
    }

    func testApplicationRootOmitsAppleBeforeResolvingItsSubmenuAndKeepsAppMenusLazy() throws {
        let menuBar = AXUIElementCreateApplication(91_600)
        let apple = AXUIElementCreateApplication(91_601)
        let appleRoot = AXUIElementCreateApplication(91_602)
        let application = AXUIElementCreateApplication(91_603)
        let applicationRoot = AXUIElementCreateApplication(91_604)
        let file = AXUIElementCreateApplication(91_605)
        let fileRoot = AXUIElementCreateApplication(91_606)
        var rootReads: [AXUIElement] = []
        let extractor = contentExtractor(
            children: [(menuBar, [apple, application, file])],
            attributes: [
                (apple, menuAttributes(title: "Apple", root: appleRoot)),
                (application, menuAttributes(title: "Example", root: applicationRoot)),
                (file, menuAttributes(title: "File", root: fileRoot))
            ],
            onReadAttribute: { element, attribute in
                guard attribute == kAXRoleAttribute as CFString else { return }
                XCTAssertFalse(CFEqual(element, appleRoot))
                rootReads.append(element)
            }
        )
        let target = MenuExtractorTarget()

        let items = try extractor.buildMenu(
            from: menuBar,
            content: .application,
            target: target,
            action: #selector(MenuExtractorTarget.activate(_:))
        )

        XCTAssertEqual(items.map(\.title), ["Example", "File"])
        XCTAssertEqual(rootReads.count, 2)
        XCTAssertNotNil(try XCTUnwrap(items[0].attributedTitle).attribute(.font, at: 0, effectiveRange: nil))
        XCTAssertTrue(try XCTUnwrap(items[0].submenu).items.isEmpty)
        XCTAssertTrue(try XCTUnwrap(items[1].submenu).items.isEmpty)
        XCTAssertTrue(items[0].submenu?.axRootElement.map { CFEqual($0, applicationRoot) } == true)
        XCTAssertTrue(items[1].submenu?.axRootElement.map { CFEqual($0, fileRoot) } == true)
    }

    func testAppleRootReturnsDirectContentsAndSkipsOtherApplicationHeaders() throws {
        let menuBar = AXUIElementCreateApplication(91_610)
        let apple = AXUIElementCreateApplication(91_611)
        let appleRoot = AXUIElementCreateApplication(91_612)
        let unrelated = AXUIElementCreateApplication(91_613)
        let about = AXUIElementCreateApplication(91_614)
        let recent = AXUIElementCreateApplication(91_615)
        let recentRoot = AXUIElementCreateApplication(91_616)
        let extractor = contentExtractor(
            children: [(menuBar, [apple, unrelated]), (appleRoot, [about, recent])],
            attributes: [
                (apple, menuAttributes(title: "Apple", root: appleRoot)),
                (about, [
                    "AXTitle": "About This Mac", "AXRole": "AXMenuItem", "AXEnabled": false,
                    "AXMenuItemMarkChar": "✓", "AXMenuItemCmdChar": "a", "AXMenuItemCmdModifiers": 8
                ]),
                (recent, menuAttributes(title: "Recent Items", root: recentRoot))
            ],
            onReadAttributes: { element in XCTAssertFalse(CFEqual(element, unrelated)) }
        )

        let items = try extractor.buildMenu(from: menuBar, content: .apple, target: nil, action: nil)

        XCTAssertEqual(items.map(\.title), ["About This Mac", "Recent Items"])
        XCTAssertFalse(items[0].isEnabled)
        XCTAssertEqual(items[0].state, .on)
        XCTAssertEqual(items[0].keyEquivalent, "a")
        XCTAssertNil(items[0].target)
        XCTAssertNil(items[0].action)
        XCTAssertTrue(try XCTUnwrap(items[1].submenu).items.isEmpty)
        XCTAssertTrue(items[1].submenu?.axRootElement.map { CFEqual($0, recentRoot) } == true)
    }

    func testAppleSelectionDistinguishesEmptyContentsFromMissingAppleRoot() throws {
        let menuBar = AXUIElementCreateApplication(91_620)
        let apple = AXUIElementCreateApplication(91_621)
        let appleRoot = AXUIElementCreateApplication(91_622)
        let empty = contentExtractor(
            children: [(menuBar, [apple]), (appleRoot, [])],
            attributes: [(apple, menuAttributes(title: "Apple", root: appleRoot))]
        )
        XCTAssertTrue(try empty.buildMenu(from: menuBar, content: .apple, target: nil, action: nil).isEmpty)

        let missing = contentExtractor(children: [(menuBar, [])], attributes: [])
        XCTAssertTrue(try missing.buildMenu(from: menuBar, content: .application, target: nil, action: nil).isEmpty)
        XCTAssertThrowsError(try missing.buildMenu(from: menuBar, content: .apple, target: nil, action: nil)) { error in
            XCTAssertEqual(error as? MenuExtractionError, .invalidResponse)
        }
    }

    func testAppleHeaderAndContentsShareOneDeadline() {
        let menuBar = AXUIElementCreateApplication(91_630)
        let apple = AXUIElementCreateApplication(91_631)
        let appleRoot = AXUIElementCreateApplication(91_632)
        var now: TimeInterval = 0
        var contentReads = 0
        let extractor = MenuExtractor(
            environment: MenuExtractorEnvironment(
                now: { now },
                readAttribute: { element, attribute, _ in
                    if CFEqual(element, menuBar) { return [apple] }
                    if attribute == kAXRoleAttribute as CFString {
                        now = 0.25
                        return kAXMenuRole as String
                    }
                    contentReads += 1
                    return [AXUIElement]()
                },
                readAttributes: { _, attributes, _ in
                    self.attributeValues(attributes, values: self.menuAttributes(title: "Apple", root: appleRoot))
                }
            )
        )

        XCTAssertThrowsError(try extractor.buildMenu(
            from: menuBar,
            content: .apple,
            target: nil,
            action: nil
        )) { error in
            XCTAssertEqual(error as? MenuExtractionError, .deadlineExceeded)
        }
        XCTAssertEqual(contentReads, 0)
    }

    private func contentExtractor(
        children: [(AXUIElement, [AXUIElement])],
        attributes: [(AXUIElement, [String: Any])],
        onReadAttribute: @escaping (AXUIElement, CFString) -> Void = { _, _ in },
        onReadAttributes: @escaping (AXUIElement) -> Void = { _ in }
    ) -> MenuExtractor {
        MenuExtractor(environment: MenuExtractorEnvironment(
            now: { 0 },
            readAttribute: { element, attribute, _ in
                onReadAttribute(element, attribute)
                if attribute == kAXRoleAttribute as CFString { return kAXMenuRole as String }
                guard let value = children.first(where: { CFEqual($0.0, element) })?.1 else {
                    throw MenuExtractionError.ax(.cannotComplete)
                }
                return value
            },
            readAttributes: { element, names, _ in
                onReadAttributes(element)
                guard let values = attributes.first(where: { CFEqual($0.0, element) })?.1 else {
                    throw MenuExtractionError.ax(.cannotComplete)
                }
                return self.attributeValues(names, values: values)
            }
        ))
    }

    private func menuAttributes(title: String, root: AXUIElement) -> [String: Any] {
        ["AXTitle": title, "AXRole": "AXMenuBarItem", "AXEnabled": true, "AXChildren": [root]]
    }

    private func attributeValues(
        _ attributes: CFArray,
        values: [String: Any]
    ) -> [Any] {
        let names = attributes as! [String]
        return names.map { values[$0] ?? (kCFNull as Any) }
    }
}
