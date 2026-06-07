// main.swift
// RunnerBar
/// Entry point — instantiates `AppDelegate` and starts the run loop.
/// Wrapped in `MainActor.assumeIsolated` because `AppDelegate` is `@MainActor`-isolated
/// via its `NSApplicationDelegate` conformance on Swift 5.10+. The OS always starts
/// execution on the main thread, so this assertion is always valid.
/// ❌ NEVER remove this wrapper — it prevents a strict-concurrency build error.
import AppKit

// RunnerBar requires Apple Silicon. Building for x86_64 is not supported.
#if !arch(arm64)
#error("RunnerBar requires Apple Silicon (arm64). x86_64 is not supported.")
#endif

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.run()
}
