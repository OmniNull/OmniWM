import CoreGraphics
import Foundation

let password = ProcessInfo.processInfo.environment["PROBE_PW"] ?? ""
let mode = CommandLine.arguments.dropFirst().first ?? "unicode"
let source = CGEventSource(stateID: .hidSystemState)
print("preflight post-event access:", CGPreflightPostEventAccess())

let keycodes: [Character: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
    "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31,
    "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
]

func press(_ code: CGKeyCode, unicode: UniChar? = nil) {
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)!
        if var character = unicode {
            event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &character)
        }
        event.post(tap: .cghidEventTap)
        usleep(15000)
    }
}

press(56)
usleep(300_000)
for character in password {
    if mode == "keycode", let code = keycodes[Character(character.lowercased())] {
        press(code)
    } else {
        press(0, unicode: character.utf16.first)
    }
}
press(36)
