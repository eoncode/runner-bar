import SwiftUI

// MARK: - BranchSelectorSheet
// #560: Sheet for selecting a branch to filter the failure hook on.
//
// Presented from ScopeDetailView when the user taps the Branch row in the
// Failure Hook section. Fetches branches from the GitHub API on a background
// thread and shows them in a searchable list.
//
// onSelect(nil)    → clears the branch filter (hook fires for all branches)
// onSelect(branch) → restricts the hook to that branch only
//
// Pagination: fetches all pages (per_page=100) until GitHub returns fewer
// than 100 results, so repos with >100 branches are fully listed.
// An empty result after a successful fetch is treated as a load error so
// the user is not misled by a silent blank list.

struct BranchSelectorSheet: View {
    let scope: String
    let onDismiss: () -> Void
    let onSelect: (String?) -> Void

    @State private var branches: [String] = []
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var loadError = false

    private var filtered: [String] {
        searchText.isEmpty
            ? branches
            : branches.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            searchSection
            Divider()
            listSection
            Divider()
            footerSection
        }
        .frame(width: 360, height: 420)
        .background(Color.rbSurfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onAppear { loadBranches() }
    }
}

// MARK: - Subviews

extension BranchSelectorSheet {
    var headerSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Select Branch")
                .font(.system(size: 13, weight: .semibold))
            Text("The failure hook will only fire when this branch fails. Leave unset to fire for all branches.")
                .font(.caption)
                .foregroundColor(Color.rbTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    var searchSection: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(Color.rbTextTertiary)
            TextField("Search branches…", text: $searchText)
                .font(.system(size: 12))
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Color.rbTextTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.rbSurface)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    var listSection: some View {
        if isLoading {
            HStack {
                Spacer()
                ProgressView()
                    .padding(.vertical, 40)
                Spacer()
            }
            .frame(maxHeight: .infinity)
        } else if loadError {
            HStack {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(Color.rbTextTertiary)
                    Text("Could not load branches")
                        .font(.caption)
                        .foregroundColor(Color.rbTextTertiary)
                }
                .padding(.vertical, 40)
                Spacer()
            }
            .frame(maxHeight: .infinity)
        } else if filtered.isEmpty {
            HStack {
                Spacer()
                Text(searchText.isEmpty ? "No branches found" : "No results for \"\(searchText)\"")
                    .font(.caption)
                    .foregroundColor(Color.rbTextTertiary)
                    .padding(.vertical, 40)
                Spacer()
            }
            .frame(maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered, id: \.self) { branch in
                        branchRow(branch)
                        if branch != filtered.last {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    func branchRow(_ branch: String) -> some View {
        Button(action: {
            log("BranchSelectorSheet › selected branch='\(branch)' for scope='\(scope)'")
            onSelect(branch)
            onDismiss()
        }) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10))
                    .foregroundColor(Color.rbTextTertiary)
                Text(branch)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color.rbTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var footerSection: some View {
        HStack {
            Button(action: {
                log("BranchSelectorSheet › cleared branch filter for scope='\(scope)'")
                onSelect(nil)
                onDismiss()
            }) {
                Label("All branches (no filter)", systemImage: "xmark.circle")
                    .font(.system(size: 11))
                    .foregroundColor(Color.rbDanger)
            }
            .buttonStyle(.plain)
            Spacer()
            Button("Cancel") { onDismiss() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.rbSurfaceElevated)
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5))
                )
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }
}

// MARK: - Data loading

extension BranchSelectorSheet {
    func loadBranches() {
        log("BranchSelectorSheet › loadBranches START scope='\(scope)'")
        DispatchQueue.global(qos: .userInitiated).async {
            let names = fetchBranchNames(scope: scope)
            DispatchQueue.main.async {
                if let names, !names.isEmpty {
                    log("BranchSelectorSheet › loadBranches — loaded \(names.count) branches")
                    branches = names
                    loadError = false
                } else {
                    log("BranchSelectorSheet › loadBranches — fetch failed or returned empty")
                    loadError = true
                }
                isLoading = false
            }
        }
    }

    /// Blocking — must be called from a background thread.
    /// Paginates through all pages (per_page=100) until GitHub returns fewer
    /// than 100 items, collecting all branch names across pages.
    private func fetchBranchNames(scope: String) -> [String]? {
        struct BranchItem: Decodable { let name: String }
        var allNames: [String] = []
        var page = 1
        while true {
            guard let data = ghAPI("repos/\(scope)/branches?per_page=100&page=\(page)") else {
                log("BranchSelectorSheet › fetchBranchNames — ghAPI returned nil scope='\(scope)' page=\(page)")
                return allNames.isEmpty ? nil : allNames.sorted()
            }
            guard let items = try? JSONDecoder().decode([BranchItem].self, from: data) else {
                log("BranchSelectorSheet › fetchBranchNames — JSON decode failed scope='\(scope)' page=\(page) dataBytes=\(data.count)")
                return allNames.isEmpty ? nil : allNames.sorted()
            }
            allNames.append(contentsOf: items.map(\.name))
            log("BranchSelectorSheet › fetchBranchNames — page=\(page) fetched=\(items.count) total=\(allNames.count)")
            if items.count < 100 { break }
            page += 1
        }
        return allNames.isEmpty ? nil : allNames.sorted()
    }
}
