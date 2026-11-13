import AppKit
import Foundation

// OpenSSH invokes this executable directly and reads its stdout through a
// private pipe. Do not log prompts, responses, environment, or arguments.
// Passwords and key passphrases are never persisted by this process.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let prompt = String((CommandLine.arguments.dropFirst().first ?? "SSH authentication required").prefix(8192))
let mode = ProcessInfo.processInfo.environment["SSH_ASKPASS_PROMPT"] ?? ""
let alert = NSAlert()
alert.informativeText = prompt
alert.icon = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil)

if mode == "confirm" {
    alert.messageText = "Verify SSH server identity"
    alert.informativeText = prompt + "\n\nCompare this fingerprint with a trusted source before accepting."
    alert.addButton(withTitle: "Trust This Server"); alert.addButton(withTitle: "Cancel")
    alert.alertStyle = .warning
    app.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { exit(1) }
    FileHandle.standardOutput.write(Data("yes\n".utf8))
} else if mode == "none" {
    alert.messageText = "SSH authentication"
    alert.addButton(withTitle: "OK")
    app.activate(ignoringOtherApps: true); _ = alert.runModal()
} else {
    alert.messageText = "Authenticate SSH destination"
    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 26))
    field.placeholderString = "Password or key passphrase"
    alert.accessoryView = field
    alert.addButton(withTitle: "Connect"); alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    app.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { exit(1) }
    var value = field.stringValue
    guard !value.contains("\n"), !value.contains("\0") else { exit(1) }
    FileHandle.standardOutput.write(Data((value + "\n").utf8))
    field.stringValue = ""; value = ""
}
exit(0)
