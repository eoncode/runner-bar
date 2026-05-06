/// Entry point — instantiates `AppDelegate` and starts the run loop.
import AppKit

/// Shared app delegate instance assigned to `NSApplication.shared.delegate`.
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
