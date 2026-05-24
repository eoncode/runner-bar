// ButtonPhaseView.swift
// RunnerBar
import SwiftUI

// MARK: - ButtonPhaseView
// swiftlint:disable:next orphaned_doc_comment
/// Animated phase indicator used on action buttons (Cancel, Re-run).
struct ButtonPhaseView: View {
    /// Represents one animation keyframe: a system-image name paired with a foreground colour.
    enum Phase: CaseIterable {
        // swiftlint:disable missing_docs
        case idle, running, done
        // swiftlint:enable missing_docs
    }
    /// The phase constant.
    let phase: Phase
    /// The body property.
    var body: some View {
        Group {
            switch phase {
            case .idle:    Image(systemName: "play.fill")
            case .running: Image(systemName: "ellipsis")
            case .done:    Image(systemName: "checkmark")
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(.white)
    }
}
