/// Entry point — instantiates `AppDelegate` and starts the run loop.
/// @MainActor required because AppDelegate is @MainActor-isolated.
/// ❌ NEVER remove MainActor.assumeIsolated — AppDelegate() init is @MainActor.
/// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
/// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
/// is major major major.
import AppKit

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.run()
}
