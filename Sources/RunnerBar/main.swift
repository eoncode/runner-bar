import AppKit

/// Entry point. Bootstraps the AppDelegate on the main actor.
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.run()
}
