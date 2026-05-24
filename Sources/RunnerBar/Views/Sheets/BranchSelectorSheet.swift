// BranchSelectorSheet.swift
// RunnerBar
// swiftlint:disable missing_docs
import RunnerBarCore
import SwiftUI

// MARK: - BranchSelectorSheet
/// Sheet for selecting a branch before triggering a workflow dispatch.
struct BranchSelectorSheet: View {
    let repo: String
    @ObservedObject var store: RunnerViewModel
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var branches: [String] = []
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider()
            sheetContent
        }
        .glassCard()
        .frame(width: 360, height: 440)
        .onAppear { loadBranches() }
    }

    // MARK: - Header
    private var sheetHeader: some View {
        HStack {
            Text("Select Branch")
                .font(.headline)
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassSection()
    }

    // MARK: - Content
    @ViewBuilder
    private var sheetContent: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = errorMessage {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2).foregroundColor(.secondary)
                Text(error)
                    .font(.caption).foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                SearchField(text: $searchText, placeholder: "Filter branches...")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                List(filteredBranches, id: \.self, selection: .constant(nil as String?)) { branch in
                    Button(action: {
                        onSelect(branch)
                        dismiss()
                    }) {
                        HStack {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Text(branch)
                                .font(.system(size: 12))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .background(Color.clear)
            }
        }
    }

    private var filteredBranches: [String] {
        searchText.isEmpty ? branches : branches.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    private func loadBranches() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let result = try await store.fetchBranches(for: repo)
                await MainActor.run {
                    branches = result
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}
// swiftlint:enable missing_docs
