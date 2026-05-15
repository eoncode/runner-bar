// swiftlint:disable redundant_discardable_let missing_docs
import AppKit
import SwiftUI

// MARK: - StepLogView
struct StepLogView: View {
    let job: ActiveJob
    let step: JobStep
    @EnvironmentObject var store: RunnerStoreObservable
    @StateObject private var fetcher = LogFetcher()
    @State private var searchText: String = ""
    @State private var matchedLines: [Int] = []
    @State private var currentMatch: Int = 0
    @Environment(\.dismiss) private var dismiss

    private var filteredLines: [(index: Int, text: String)] {
        guard !searchText.isEmpty else {
            return fetcher.lines.enumerated().map { ($0.offset, $0.element) }
        }
        return fetcher.lines.enumerated()
            .filter { $0.element.localizedCaseInsensitiveContains(searchText) }
            .map { ($0.offset, $0.element) }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if fetcher.isLoading {
                ProgressView("Loading log…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = fetcher.error {
                Text("Error: \(err)")
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                logScrollView
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .onAppear {
            fetcher.fetch(jobID: job.id, stepNumber: step.number,
                          token: store.state.settings.githubToken,
                          org: store.state.settings.githubOrg)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.name).font(.headline).lineLimit(1)
                Text(step.name ?? "Step \(step.number)").font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            LogCopyButton(lines: fetcher.lines)
            searchBar
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var searchBar: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.caption)
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .frame(width: 140)
                .onChange(of: searchText) { _ in
                    matchedLines = filteredLines.map(\.index)
                    currentMatch = 0
                }
            if !matchedLines.isEmpty {
                Text("\(currentMatch + 1)/\(matchedLines.count)")
                    .font(.caption2).foregroundColor(.secondary)
                Button(action: { if currentMatch > 0 { currentMatch -= 1 } }) {
                    Image(systemName: "chevron.up").font(.caption2)
                }.buttonStyle(.plain)
                Button(action: { if currentMatch < matchedLines.count - 1 { currentMatch += 1 } }) {
                    Image(systemName: "chevron.down").font(.caption2)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
    }

    private var logScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredLines, id: \.index) { item in
                        logLine(item.index, text: item.text)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .onChange(of: currentMatch) { _ in
                if !matchedLines.isEmpty {
                    withAnimation { proxy.scrollTo(matchedLines[currentMatch], anchor: .center) }
                }
            }
        }
    }

    private func logLine(_ index: Int, text: String) -> some View {
        let isHighlighted = matchedLines.contains(index) && matchedLines[safe: currentMatch] == index
        return HStack(alignment: .top, spacing: 6) {
            Text(String(format: "%4d", index + 1))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.5))
                .frame(width: 32, alignment: .trailing)
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(lineColor(text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
        .background(isHighlighted ? Color.yellow.opacity(0.25) : Color.clear)
        .id(index)
    }

    private func lineColor(_ text: String) -> Color {
        let lower = text.lowercased()
        if lower.contains("error") || lower.contains("failed") { return DesignTokens.Colors.statusRed }
        if lower.contains("warning") { return DesignTokens.Colors.statusOrange }
        if lower.contains("success") || lower.contains("passed") { return DesignTokens.Colors.statusGreen }
        return .primary
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
// swiftlint:enable redundant_discardable_let missing_docs
