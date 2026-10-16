// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ImageIO
import OpenDirectory

struct ShellUser: Equatable, Sendable, ShellValueWritable {
    static let avatarId = "user.avatar"

    var name: String
    var account: String
    var avatar = false

    func write(into writer: inout ShellValueWriter) {
        writer.map(3)
        writer.key("name")
        writer.string(name)
        writer.key("account")
        writer.string(account)
        writer.key("avatar")
        if avatar {
            writer.string(Self.avatarId)
        } else {
            writer.null()
        }
    }
}

@MainActor
final class UserMonitor: ShellDeviceSource {
    private(set) var value: ShellUser?
    var onChange: ((ShellUser?) -> Void)?
    private var picture: CGImage?
    private var generation = 0
    private var listening = false

    func setListening(_ listening: Bool) {
        guard listening != self.listening else { return }
        self.listening = listening
        generation += 1
        guard listening else {
            value = nil
            picture = nil
            return
        }
        value = ShellUser(name: NSFullUserName(), account: NSUserName())
        let generation = generation
        let account = NSUserName()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let image = Self.picture(of: account)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.received(image, generation: generation)
                }
            }
        }
    }

    private func received(_ image: CGImage?, generation: Int) {
        guard generation == self.generation, let image else { return }
        picture = image
        value?.avatar = true
        onChange?(value)
    }

    func bitmap(_ id: String) -> CGImage? {
        id == ShellUser.avatarId ? picture : nil
    }

    nonisolated static func picture(of account: String) -> CGImage? {
        guard let node = try? ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeLocalNodes)),
              let record = try? node.record(
                  withRecordType: kODRecordTypeUsers,
                  name: account,
                  attributes: [kODAttributeTypeJPEGPhoto, kODAttributeTypePicture]
              )
        else {
            return nil
        }
        if let data = (try? record.values(forAttribute: kODAttributeTypeJPEGPhoto))?.first as? Data,
           let image = thumbnail(CGImageSourceCreateWithData(data as CFData, nil))
        {
            return image
        }
        guard let path = (try? record.values(forAttribute: kODAttributeTypePicture))?.first as? String else {
            return nil
        }
        return thumbnail(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
    }

    private nonisolated static func thumbnail(_ source: CGImageSource?) -> CGImage? {
        source.flatMap {
            CGImageSourceCreateThumbnailAtIndex($0, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 256
            ] as CFDictionary)
        }
    }
}
