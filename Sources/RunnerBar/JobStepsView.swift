import SwiftUI

// MARK: - Job Steps View

struct JobStepsView: View {
    let job: ActiveJob
    let scope: String
    let onBack: () -> Void

    @State private var steps: [JobStep] = []
    @State private var isLoading = true
    @State private var tick = 0
    @State private var selectedStep: JobStep? = nil

    var body: some View {
        Group {
            if let step = selectedStep {
                StepLogView(
                    job: job,
                    step: step,
                    scope: scope,
                    onBack: { selectedStep = nil }
                )
            } else {
                stepsListView
            }
        }
        .frame(width: 340, height: 480)
    }

    // MARK: - Steps list

    private var stepsListView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {

                // ── Header
                HStack(spacing: 6) {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)

                    Text(job.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

                Divider()

                // ── Steps
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView().padding(.vertical, 16)
                        Spacer()
                    }
                } else if steps.isEmpty {
                    Text("No steps found")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                } else {
                    ForEach(steps) { step in
                        let tappable = step.status == "completed" && !step.isSkipped
                        Button(action: {
                            guard tappable else { return }
                            selectedStep = step
                        }) {
                            HStack(spacing: 8) {
                                stepDot(for: step)

                                Text(step.name)
                                    .font(.system(size: 12))
                                    .foregroundColor(step.isDimmed ? .secondary : .primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)

                                Spacer()

                                if step.status == "completed" || step.isSkipped {
                                    Text(conclusionLabel(for: step))
                                        .font(.caption)
                                        .foregroundColor(conclusionColor(for: step))
                                        .frame(width: 76, alignment: .trailing)
                                } else {
                                    Text(statusLabel(for: step))
                                        .font(.caption)
                                        .foregroundColor(statusColor(for: step))
                                        .frame(width: 76, alignment: .trailing)
                                }

                                Text(liveElapsed(for: step))
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.secondary)
                                    .frame(width: 40, alignment: .trailing)

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9))
                                    .foregroundColor(tappable ? .secondary.opacity(0.5) : .clear)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .opacity(step.isDimmed ? 0.5 : 1.0)
                    }
                    .padding(.bottom, 6)
                }

            } // VStack
        } // ScrollView
        .onAppear { loadSteps() }
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in tick += 1 }
        }
    }

    // MARK: - Data

    private func loadSteps() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = fetchJobSteps(jobID: job.id, scope: scope)
            DispatchQueue.main.async {
                steps = result
                isLoading = false
            }
        }
    }

    // MARK: - Helpers

    private func liveElapsed(for step: JobStep) -> String {
        _ = tick
        return step.elapsed
    }

    @ViewBuilder
    private func stepDot(for step: JobStep) -> some View {
        Circle()
            .fill(dotColor(for: step))
            .frame(width: 7, height: 7)
    }

    private func dotColor(for step: JobStep) -> Color {
        switch step.status {
        case "in_progress": return .yellow
        case "completed":
            switch step.conclusion {
            case "success": return .green
            case "failure": return .red
            default:        return .secondary
            }
        default: return .gray
        }
    }

    private func statusLabel(for step: JobStep) -> String {
        step.status == "in_progress" ? "In Progress" : "Queued"
    }

    private func statusColor(for step: JobStep) -> Color {
        step.status == "in_progress" ? .yellow : .secondary
    }

    private func conclusionLabel(for step: JobStep) -> String {
        switch step.conclusion {
        case "success":   return "✓ success"
        case "failure":   return "✗ failure"
        case "skipped":   return "− skipped"
        case "cancelled": return "⊖ cancelled"
        default:          return step.conclusion ?? "done"
        }
    }

    private func conclusionColor(for step: JobStep) -> Color {
        switch step.conclusion {
        case "success": return .green
        case "failure": return .red
        default:        return .secondary
        }
    }
}
