import AppKit

// main.swift — app entry point.
// AppDelegate is wired manually rather than via @NSApplicationMain or @main
// because this is a SwiftPM executable target (Sources/RunnerBar/main.swift is
// the designated entry file). The @main attribute requires a type with a static
// main() and is incompatible with SwiftPM executable targets that already have
// a main.swift — the compiler would report a duplicate entry point.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
