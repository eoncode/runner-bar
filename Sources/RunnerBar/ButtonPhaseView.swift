// swiftlint:disable all
// force-v2
import SwiftUI

enum ButtonPhase {
    case idle, loading, success, failure
}

struct ButtonPhaseView: View {
    let phase: ButtonPhase
    let idleLabel: String
    let idleIcon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                switch phase {
                case .idle:
                    Image(systemName: idleIcon).font(.caption)
                    Text(idleLabel).font(.caption)
                case .loading:
                    ProgressView().scaleEffect(0.6)
                case .success:
                    Image(systemName: "checkmark").font(.caption).foregroundColor(.rbSuccess)
                case .failure:
                    Image(systemName: "xmark").font(.caption).foregroundColor(.rbDanger)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .disabled(phase == .loading)
    }
}
