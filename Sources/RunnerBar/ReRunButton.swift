import SwiftUI

/// Top-bar re-run button. Mirrors LogCopyButton phase-machine pattern.
/// idle (arrow.clockwise + "Re-run") → loading (spinner + "Running…") → done (✓ + "Done", 1.5s) OR failed (✗ + "Failed", 1.5s) → idle
struct ReRunButton: View {
   /// Called on tap. Must call completion(success: Bool) from any thread.
   let action: (@escaping (Bool) -> Void) -> Void
   var isDisabled: Bool = false

   @State private var phase: Phase = .idle

   enum Phase { case idle, loading, done, failed }

   var body: some View {
      Group {
         switch phase {
         case .idle:
            Button {
               startRerun()
            } label: {
               HStack(spacing: 4) {
                  Image(systemName: "arrow.clockwise")
                     .font(.caption)
                  Text("Re-run")
                     .font(.caption)
               }
               .foregroundColor(isDisabled ? .secondary.opacity(0.4) : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
         case .loading:
            HStack(spacing: 4) {
               ProgressView().controlSize(.mini)
               Text("Running…")
                  .font(.caption)
                  .foregroundColor(.secondary)
            }
         case .done:
            HStack(spacing: 4) {
               Image(systemName: "checkmark")
                  .font(.caption)
                  .foregroundColor(.green)
               Text("Done")
                  .font(.caption)
                  .foregroundColor(.green)
            }
         case .failed:
            HStack(spacing: 4) {
               Image(systemName: "xmark")
                  .font(.caption)
                  .foregroundColor(.red)
               Text("Failed")
                  .font(.caption)
                  .foregroundColor(.red)
            }
         }
      }
      .fixedSize()
   }

   private func startRerun() {
      guard phase == .idle else { return }
      phase = .loading
      action { success in
         DispatchQueue.main.async {
            phase = success ? .done : .failed
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
               phase = .idle
            }
         }
      }
   }
}
