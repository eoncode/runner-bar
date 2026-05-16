import AppKit
import SwiftUI

// swiftlint:disable type_body_length
// swiftlint:disable file_length

// MARK: - NavState

// ⚠️ ARCHITECTURE: NSPanel (Pattern 2 from #377) — READ BEFORE CHANGING.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major. Full rationale lives in PR #377.
// TL;DR: popup panel MUST use NSPanel + NSWindow.Level.popUpMenu.
// Using NSPopover caused the panel to hide under fullscreen spaces; using a plain
// NSWindow caused it to appear behind Dock icons in some macOS 14 configs.
// Pattern 2 was chosen after exhaustive testing of all five NSPanel patterns.
import AppKit
import Combine
import Foundation
import SwiftUI
