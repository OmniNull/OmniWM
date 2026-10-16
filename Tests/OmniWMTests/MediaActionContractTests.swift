// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMIPC
import XCTest

final class MediaActionContractTests: XCTestCase {
    func testVolumeAndMediaActionsAreUnassignedSharedHotkeysWithIPCNames() throws {
        let expected: [(IPCMediaCommand, String, String, String)] = [
            (.volumeUp, "volumeUp", "volume-up", "Volume Up"),
            (.volumeDown, "volumeDown", "volume-down", "Volume Down"),
            (.volumeMute, "volumeMute", "volume-mute", "Mute or Unmute Volume"),
            (.playPause, "mediaPlayPause", "media-play-pause", "Play or Pause Media"),
            (.next, "mediaNext", "media-next", "Next Track"),
            (.previous, "mediaPrevious", "media-previous", "Previous Track")
        ]
        XCTAssertEqual(expected.map(\.0), IPCMediaCommand.allCases)
        for (ipc, id, name, title) in expected {
            let command = HotkeyCommand.media(ipc)
            let spec = try XCTUnwrap(ActionCatalog.spec(for: command))
            XCTAssertEqual(ActionCatalog.spec(for: id), spec)
            XCTAssertEqual(spec.title, title)
            XCTAssertEqual(spec.defaultBinding, .unassigned)
            XCTAssertEqual(spec.category, .focus)
            XCTAssertEqual(spec.ipcCommandName, .media(ipc))
            XCTAssertEqual(command.layoutCompatibility, .shared)
            XCTAssertEqual(IPCCommandName(rawValue: name), .media(ipc))
            XCTAssertEqual(try IPCCommandRequest(name: .media(ipc)), .media(ipc))
            XCTAssertEqual(IPCAutomationManifest.commandDescriptor(for: .media(ipc))?.commandWords, [name])
        }
    }
}
