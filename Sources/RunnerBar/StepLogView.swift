import SwiftUI
import AppKit

// ── StepLogView ──────────────────────────────────────────────────────────────
//
// Third navigation level: main → JobDetailView → StepLogView.
// Fetches raw log text for the parent job via:
//   gh api repos/{scope}/actions/jobs/{jobId}/logs
// then filters lines that belong to this step using the "##[group]" / step-number
// prefix pattern GitHub Actions injects into log output.
//
// ARCHITECTURE NOTES:
//   • Log fetch runs on a background thread (DispatchQueue.global).
//   • View state updates happen on DispatchQueue.main.
//   • No size changes, no hc.rootView changes here.
//   • Frame: .frame(maxWidth:.infinity, maxHeight:.infinity, alignment:.top)
//     — matches JobDetailView's frame contract so ScrollView fills the popover.
//   ❌ NEVER call navigate() or touch contentSize from this view.
//   ❌ NEVER use .fixedSize() or .frame(height:) on root container.
struct StepLogView: View {
    let job: ActiveJob
    let step: JobStep
    let onBack: () -> Void

    @State private var lines: [String] = []
    @State private var isLoading = true
    @State private var errorMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header: back + step name (OUTSIDE ScrollView — always visible)
            HStack(spacing: 6) {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.caption)
                        Text("Steps").font(.caption)
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                Spacer()  // ⚠️ load-bearing — do NOT remove
                Text(step.elapsed)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)

            Text(step.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

            Divider()

            // ── Log content: INSIDE ScrollView
            ScrollView(.vertical, showsIndicators: true) {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView().scaleEffect(0.7)
                        Text("Loading log…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 16)
                } else if let err = errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                } else if lines.isEmpty {
                    Text("No log output for this step.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.primary)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        // ⚠️ Fill fixed frame from AppDelegate. Pin to top.
        // ScrollView above absorbs all overflow.
        // ❌ NEVER add idealWidth — fittingSize is read from mainView(), not here
        // ❌ NEVER add .frame(height:) — fights AppDelegate's frame
        // ❌ NEVER add .fixedSize() — collapses view
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { fetchLog() }
    }

    // MARK: — Log fetching

    private func fetchLog() {
        isLoading = true
        errorMessage = nil
        lines = []

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.loadStepLog(job: job, step: step)
            DispatchQueue.main.async {
                isLoading = false
                switch result {
                case .success(let logLines):
                    lines = logLines
                case .failure(let err):
                    errorMessage = err
                }
            }
        }
    }

    // Fetches full job log and filters to lines for this step.
    // GitHub Actions log format:
    //   Each line starts with a timestamp: "2024-01-01T00:00:00.0000000Z "
    //   Step sections are delimited by:
    //     "##[group]..." lines (group start)
    //     "##[endgroup]" lines (group end)
    //   Step N in the log corresponds to step index N (1-based).
    //
    // Strategy: capture lines between the Nth "##[group]" and its "##[endgroup]".
    // Strip ANSI escape sequences and the timestamp prefix.
    private static func loadStepLog(job: ActiveJob, step: JobStep) -> Result<[String], String> {
        // Derive scope from htmlUrl: "https://github.com/owner/repo/actions/runs/.../jobs/..."
        guard let htmlUrl = job.htmlUrl,
              let scope = scopeFromHtmlUrl(htmlUrl) else {
            return .failure("Cannot determine repository from job URL.")
        }

        let endpoint = "repos/\(scope)/actions/jobs/\(job.id)/logs"
        guard let data = ghAPILog(endpoint),
              let raw = String(data: data, encoding: .utf8) else {
            return .failure("Failed to fetch log. Check gh auth and network.")
        }

        let filtered = filterLines(raw: raw, stepIndex: step.id)
        return .success(filtered)
    }

    // Extract "owner/repo" from a GitHub job HTML URL.
    // e.g. "https://github.com/acme/myrepo/actions/runs/12345/jobs/67890"
    //   → "acme/myrepo"
    private static func scopeFromHtmlUrl(_ url: String) -> String? {
        // Remove scheme + host
        guard let u = URL(string: url),
              let host = u.host, host == "github.com" else { return nil }
        let parts = u.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        // parts[0] = owner, parts[1] = repo
        guard parts.count >= 2 else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    // Fetch job log bytes via `gh api` (no JSON parsing — raw text).
    private static func ghAPILog(_ endpoint: String) -> Data? {
        let gh = "/opt/homebrew/bin/gh"
        guard FileManager.default.isExecutableFile(atPath: gh) else { return nil }
        let task = Process()
        let pipe = Pipe()
        task.executableURL  = URL(fileURLWithPath: gh)
        task.arguments      = ["api", endpoint, "--header", "Accept: application/vnd.github.v3.raw"]
        task.standardOutput = pipe
        task.standardError  = Pipe()
        var data = Data()
        let lock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            lock.lock(); data.append(chunk); lock.unlock()
        }
        do { try task.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(30)
        while task.isRunning { if Date() > deadline { task.terminate(); break }; Thread.sleep(forTimeInterval: 0.05) }
        pipe.fileHandleForReading.readabilityHandler = nil
        let tail = pipe.fileHandleForReading.readDataToEndOfFile()
        if !tail.isEmpty { lock.lock(); data.append(tail); lock.unlock() }
        return data.isEmpty ? nil : data
    }

    // Filter raw log lines to those belonging to step N (1-based).
    // GitHub log format: groups are delimited by ##[group] / ##[endgroup] markers.
    // We collect lines in the Nth group block.
    private static func filterLines(raw: String, stepIndex: Int) -> [String] {
        var result: [String] = []
        var groupCount = 0
        var inTarget = false

        for raw_line in raw.components(separatedBy: "\n") {
            let line = stripTimestamp(stripANSI(raw_line))

            if line.contains("##[group]") {
                groupCount += 1
                inTarget = (groupCount == stepIndex)
                // Include the group header line itself
                if inTarget {
                    let label = line.replacingOccurrences(of: "##[group]", with: "").trimmingCharacters(in: .whitespaces)
                    if !label.isEmpty { result.append(label) }
                }
                continue
            }

            if line.contains("##[endgroup]") {
                if inTarget { inTarget = false }
                continue
            }

            if inTarget && !line.isEmpty {
                result.append(line)
            }
        }

        // Fallback: if no group markers found (simple jobs), return all non-empty lines
        if result.isEmpty && groupCount == 0 {
            return raw.components(separatedBy: "\n")
                .map { stripTimestamp(stripANSI($0)) }
                .filter { !$0.isEmpty }
        }

        return result
    }

    // Strip ANSI escape codes (colours, cursor moves, etc.)
    private static func stripANSI(_ s: String) -> String {
        // Matches ESC [ ... m and similar sequences
        var result = s
        // Simple regex-free approach: scan for ESC char
        var out = ""
        var i = result.startIndex
        while i < result.endIndex {
            let c = result[i]
            if c == "\u{1B}" {
                // Skip until we hit a letter that ends the escape sequence
                var j = result.index(after: i)
                while j < result.endIndex {
                    let ec = result[j]
                    j = result.index(after: j)
                    if ec.isLetter || ec == "m" || ec == "K" || ec == "J" || ec == "H" || ec == "A" || ec == "B" || ec == "C" || ec == "D" { break }
                }
                i = j
            } else {
                out.append(c)
                i = result.index(after: i)
            }
        }
        return out
    }

    // Strip GitHub Actions timestamp prefix:
    // "2024-01-15T12:34:56.1234567Z " → rest of string
    private static func stripTimestamp(_ s: String) -> String {
        // Timestamps are 28 chars: "YYYY-MM-DDTHH:MM:SS.0000000Z "
        guard s.count > 29 else { return s }
        let idx = s.index(s.startIndex, offsetBy: 29, limitedBy: s.endIndex) ?? s.endIndex
        let candidate = String(s[..<idx])
        // Verify it looks like a timestamp (starts with digit, contains T and Z)
        if candidate.first?.isNumber == true && candidate.contains("T") && candidate.contains("Z") {
            return String(s[idx...])
        }
        return s
    }
}
