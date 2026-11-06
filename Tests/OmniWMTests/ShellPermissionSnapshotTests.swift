// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ShellPermissionSnapshotTests: XCTestCase {
    private let principal = ShellWidgetPrincipal(role: .component, name: "converter", source: "/shell/converter")

    private func approval(_ digest: String = "first", command: [String] = ["provider.pl"]) -> ShellProviderApproval {
        ShellProviderApproval(principal: principal, command: command, sha256: digest)
    }

    func testProgramConsentBindsTheSourceCommandAndExecutableDigest() {
        let permissions = ShellNetworkPermissions()
        XCTAssertEqual(permissions.decide(approval()), .notApproved)
        var decisions = ShellPermissionDecisions()
        decisions.setProgram(.allowed, for: approval())
        XCTAssertTrue(permissions.update(decisions: decisions))
        XCTAssertEqual(permissions.decide(approval()), .allowed)
        XCTAssertEqual(permissions.decide(approval("changed")), .notApproved)
        XCTAssertEqual(permissions.decide(approval(command: ["provider.pl", "new-argument"])), .notApproved)
        let other = ShellProviderApproval(
            principal: .init(role: .component, name: principal.name, source: "/other/converter"),
            command: ["provider.pl"], sha256: "first"
        )
        XCTAssertEqual(permissions.decide(other), .notApproved)
        XCTAssertEqual(permissions.approvedDigest(for: principal, command: ["provider.pl"]), "first")
    }

    func testProgramDenialAndManagedDisableOverrideAnApprovedDigest() {
        var decisions = ShellPermissionDecisions()
        decisions.setProgram(.allowed, for: approval())
        let permissions = ShellNetworkPermissions(decisions: decisions)
        var managed = ShellManagedPolicy()
        managed.providersAllowed = false
        XCTAssertTrue(permissions.update(managed: managed))
        XCTAssertEqual(permissions.decide(approval()), .blocked)
        XCTAssertNil(permissions.approvedDigest(for: principal, command: ["provider.pl"]))
        XCTAssertTrue(permissions.update(managed: ShellManagedPolicy()))
        decisions.setProgram(.denied, for: approval())
        XCTAssertTrue(permissions.update(decisions: decisions))
        XCTAssertEqual(permissions.decide(approval()), .denied)
        XCTAssertEqual(permissions.decide(approval("changed")), .denied)
        decisions.setProgram(nil, for: approval())
        XCTAssertTrue(permissions.update(decisions: decisions))
        XCTAssertEqual(permissions.decide(approval()), .notApproved)
    }

    func testProgramServiceAndManagedOnlyChangesAdvanceTheSnapshotRevision() {
        let permissions = ShellNetworkPermissions()
        var decisions = ShellPermissionDecisions()
        var revision = permissions.snapshot.revision
        decisions.setProgram(.allowed, for: approval())
        XCTAssertTrue(permissions.update(decisions: decisions))
        XCTAssertGreaterThan(permissions.snapshot.revision, revision)
        revision = permissions.snapshot.revision
        decisions.services.lyrics = false
        XCTAssertTrue(permissions.update(decisions: decisions))
        XCTAssertGreaterThan(permissions.snapshot.revision, revision)
        revision = permissions.snapshot.revision
        var managed = ShellManagedPolicy()
        managed.providersAllowed = false
        XCTAssertTrue(permissions.update(managed: managed))
        XCTAssertGreaterThan(permissions.snapshot.revision, revision)
        revision = permissions.snapshot.revision
        managed.blockedServices = [.weather]
        XCTAssertTrue(permissions.update(managed: managed))
        XCTAssertGreaterThan(permissions.snapshot.revision, revision)
        revision = permissions.snapshot.revision
        XCTAssertFalse(permissions.update(decisions: decisions, managed: managed))
        XCTAssertEqual(permissions.snapshot.revision, revision)
    }

    func testBuiltInsDefaultOnAndRestrictEveryURLToTheirFixedHTTPSHosts() throws {
        let permissions = ShellNetworkPermissions()
        for service in ShellBuiltInService.allCases {
            XCTAssertEqual(permissions.access(service), .ok)
            for host in service.hosts {
                XCTAssertTrue(permissions.permits(try XCTUnwrap(URL(string: "https://\(host)/api")), service: service))
                XCTAssertFalse(permissions.permits(try XCTUnwrap(URL(string: "http://\(host)/api")), service: service))
                XCTAssertFalse(permissions.permits(
                    try XCTUnwrap(URL(string: "https://user:password@\(host)/api")), service: service
                ))
            }
            XCTAssertFalse(permissions.permits(try XCTUnwrap(URL(string: "https://unknown.example")), service: service))
        }
    }

    func testBuiltInTogglesAndManagedHostRestrictionsApplyWithoutWidgetGrants() {
        var decisions = ShellPermissionDecisions()
        decisions.services.lyrics = false
        let permissions = ShellNetworkPermissions(decisions: decisions)
        XCTAssertEqual(permissions.access(.lyrics), .off)
        XCTAssertEqual(permissions.access(.weather), .ok)
        var managed = ShellManagedPolicy()
        managed.blockedHosts = ["lrclib.net"]
        XCTAssertTrue(permissions.update(managed: managed))
        XCTAssertEqual(permissions.access(.lyrics), .blocked)
        managed.blockedHosts = []
        managed.onlyAllowedHosts = true
        managed.allowedHosts = ["lrclib.net", "api.open-meteo.com"]
        XCTAssertTrue(permissions.update(managed: managed))
        XCTAssertEqual(permissions.access(.weather), .blocked)
        managed.allowedHosts.insert("geocoding-api.open-meteo.com")
        XCTAssertTrue(permissions.update(managed: managed))
        XCTAssertEqual(permissions.access(.weather), .ok)
        managed.blockedServices = [.weather]
        XCTAssertTrue(permissions.update(managed: managed))
        XCTAssertEqual(permissions.access(.weather), .blocked)
    }

    func testSettingsMutationsPublishProgramAndServiceDecisions() {
        let settings = ShellPermissionSettings()
        var changes = 0
        settings.onDecisionsChange = { changes += 1 }
        settings.setProgram(.allowed, for: approval())
        settings.setServiceEnabled(false, service: .weather)
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(settings.decisions.programs.first?.sha256, "first")
        XCTAssertFalse(settings.decisions.services.weather)
        settings.setServiceEnabled(false, service: .weather)
        XCTAssertEqual(changes, 2)
    }

    func testDuplicateProgramRecordsCannotOverrideADenial() throws {
        var decisions = ShellPermissionDecisions()
        decisions.setProgram(.denied, for: approval())
        var allowed = try XCTUnwrap(decisions.programs.first)
        allowed.denied = false
        decisions.programs.append(allowed)
        XCTAssertEqual(ShellNetworkPermissions(decisions: decisions).decide(approval()), .denied)
        decisions.programs.reverse()
        XCTAssertEqual(ShellNetworkPermissions(decisions: decisions).decide(approval()), .denied)
    }

    func testProviderApprovalEventsCoalesceAndPreserveAChangedDigest() async {
        let delivered = expectation(description: "provider approvals reach the main-actor registry")
        var approvals: [ShellProviderApproval] = []
        let outbox = ShellWidgetOutbox { batch in
            approvals += batch["test"]?.providerApprovals ?? []
            delivered.fulfill()
        }
        outbox.providerApproval(name: "test", generation: 1, approval: approval())
        outbox.providerApproval(name: "test", generation: 1, approval: approval())
        outbox.providerApproval(name: "test", generation: 1, approval: approval("changed"))
        await fulfillment(of: [delivered], timeout: failureBound)
        XCTAssertEqual(approvals, [approval(), approval("changed")])
    }
}
