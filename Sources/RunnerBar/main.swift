import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu-bar only — no Dock icon, no auto-quit
let delegate = AppDelegate()
app.delegate = delegate
app.run()
