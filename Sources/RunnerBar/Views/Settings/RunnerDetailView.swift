// RunnerDetailView.swift
// RunnerBar
// swiftlint:disable file_length type_body_length
import RunnerBarCore
import SwiftUI

// MARK: - RunnerDetailView
/// Detail panel shown when a runner is selected in the Settings sidebar.
struct RunnerDetailView: View {
    let runner: RunnerModel
    @ObservedObject var store: RunnerViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                headerSection
                identitySection
                statusSection
                labelsSection
                hooksSection
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Header
    private var headerSection: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(runner.isOnline ? Color.rbSuccess : Color.rbTextTertiary)
                .frame(width: 10, height: 10)
            Text(runner.runnerName)
                .font(.title3.weight(.semibold))
            Spacer()
            Text(runner.isOnline ? "Online" : "Offline")
                .font(.caption)
                .foregroundColor(runner.isOnline ? .rbSuccess : .secondary)
        }
        .padding(12)
        .glassSection()
    }

    // MARK: - Identity
    private var identitySection: some View {
        detailCard {
            labeledRow("Scope", value: runner.scope)
            labeledRow("OS", value: runner.os ?? "Unknown")
            labeledRow("Architecture", value: runner.architecture ?? "Unknown")
        }
    }

    // MARK: - Status
    private var statusSection: some View {
        detailCard {
            labeledRow("Status", value: runner.status ?? "Unknown")
            labeledRow("Busy", value: runner.isBusy ? "Yes" : "No")
        }
    }

    // MARK: - Labels
    private var labelsSection: some View {
        detailCard {
            Text("Labels")
                .font(RBFont.sectionCaption)
                .foregroundColor(.secondary)
            if runner.labels.isEmpty {
                Text("None")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                FlowLayout(spacing: 4) {
                    ForEach(runner.labels, id: \.self) { label in
                        Text(label)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.rbSurfaceElevated, in: Capsule())
                    }
                }
            }
        }
    }

    // MARK: - Hooks
    private var hooksSection: some View {
        detailCard {
            labeledRow("Failure hook", value: runner.failureHookCommand ?? "None")
        }
    }

    // MARK: - Helpers
    private func detailCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func labeledRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundColor(.primary)
                .textSelection(.enabled)
            Spacer()
        }
    }
}
// swiftlint:enable file_length type_body_length
