import SwiftUI

// ── System stats: ONE row, never bleeds to second row ────────────────────────
//
// CPU [▓░░] 29.7%  MEM [▓▓▓░] 1.6/16.0GB  DISK [▓▓▓▓▓░] 335/460GB (126GB 27%)
//
// RULE: .lineLimit(1) is load-bearing. Do not remove.
// RULE: bar width 16pt, height 5pt.
// RULE: segment spacing 6pt.
// COLOR: all three segments use usageColor(pct: usedPct) — same as ci-dash.py:
//   dc = R if dp > 85 else Y if dp > 60 else G

struct SystemStatsView: View {
    let stats: SystemStats

    var body: some View {
        HStack(spacing: 6) {
            cpuSegment
            memSegment
            diskSegment
        }
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // ── CPU ──────────────────────────────────────────────────────────────────

    private var cpuSegment: some View {
        HStack(spacing: 4) {
            Text("CPU").font(.caption2).foregroundColor(.secondary)
            bar(fraction: stats.cpuPct / 100, color: usageColor(pct: stats.cpuPct))
            Text(String(format: "%.1f%%", stats.cpuPct))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(usageColor(pct: stats.cpuPct))
        }
    }

    // ── MEM ──────────────────────────────────────────────────────────────────

    private var memSegment: some View {
        let usedPct = stats.memTotalGB > 0 ? (stats.memUsedGB / stats.memTotalGB) * 100 : 0
        return HStack(spacing: 4) {
            Text("MEM").font(.caption2).foregroundColor(.secondary)
            bar(fraction: usedPct / 100, color: usageColor(pct: usedPct))
            Text(String(format: "%.1f/%.1fGB", stats.memUsedGB, stats.memTotalGB))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(usageColor(pct: usedPct))
        }
    }

    // ── DISK ─────────────────────────────────────────────────────────────────
    // Color on used% — matches ci-dash.py: dc = R if dp > 85 else Y if dp > 60 else G
    // Free label: (126GB 27%) — no "free:" prefix to save space

    private var diskSegment: some View {
        let usedPct = stats.diskTotalGB > 0 ? (stats.diskUsedGB / stats.diskTotalGB) * 100 : 0
        let color   = usageColor(pct: usedPct)
        return HStack(spacing: 4) {
            Text("DISK").font(.caption2).foregroundColor(.secondary)
            bar(fraction: usedPct / 100, color: color)
            Text(String(format: "%d/%dGB (%dGB %d%%)",
                        Int(stats.diskUsedGB.rounded()),
                        Int(stats.diskTotalGB.rounded()),
                        Int(stats.diskFreeGB.rounded()),
                        Int(stats.diskFreePct.rounded())))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(color)
        }
    }

    // ── Bar ──────────────────────────────────────────────────────────────────

    private func bar(fraction: Double, color: Color) -> some View {
        GeometryReader { _ in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.primary.opacity(0.1))
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 16 * max(0, min(1, fraction)))
            }
        }
        .frame(width: 16, height: 5)
    }

    // ── Colors ───────────────────────────────────────────────────────────────
    // Matches ci-dash.py exactly: R if pct > 85 else Y if pct > 60 else G

    private func usageColor(pct: Double) -> Color {
        if pct > 85 { return .red }
        if pct > 60 { return .yellow }
        return .green
    }
}
