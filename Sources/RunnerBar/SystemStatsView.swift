import SwiftUI

// ── SystemStatsView ───────────────────────────────────────────────────────────
//
// Renders a single horizontal row of three metric segments:
//
//   CPU [▓░░] 20.1%  MEM [▓▓░] 7.2/16.0GB  DISK [▓▓▓] 335/460GB (126GB 27%)
//
// LAYOUT CONSTRAINTS (do not violate — popover width is tight at 420 pt):
//
//   • .lineLimit(1) is LOAD-BEARING.
//     Without it, the DISK label can wrap to a second line and break the
//     popover height calculation in AppDelegate (fittingSize).
//
//   • Bar width is 16 pt, height 5 pt.
//     Reducing bar width frees space for the longer DISK text label.
//     Do NOT use .frame(maxWidth:) on bars — it fights the fixed 16 pt.
//
//   • HStack segment spacing is 6 pt. Tighter than 4 pt looks cramped;
//     looser than 8 pt risks truncation on smaller screens.
//
// COLOR LOGIC (mirrors ci-dash.py render_system exactly):
//   CPU/MEM: color on used%    — cc = R>85 Y>60 G≤60
//   DISK:    color on used%    — dc = R>85 Y>60 G≤60
//   All three use the same usageColor(pct:) helper.
//   WHY used% for DISK (not free%)?
//     ci-dash.py calculates: dp = (du / dt * 100), then dc = R>85 Y>60 G≤60
//     At 335/460 GB used → dp = 72.8 % → yellow. This matches the terminal UI.
//
// DISK LABEL FORMAT:
//   "335/460GB (126GB 27%)" — used/total then free in parens.
//   The "free:" prefix was dropped to save ~5 pt of horizontal space.
//   Integers (not .1f) are used for GB values because fractional GB is noise
//   at disk scales.

struct SystemStatsView: View {
    /// Injected snapshot — updated every 2 s by SystemStatsViewModel.
    let stats: SystemStats

    var body: some View {
        HStack(spacing: 6) {
            cpuSegment
            memSegment
            diskSegment
        }
        // CRITICAL: .lineLimit(1) prevents the DISK label from wrapping and
        // breaking fittingSize-based popover height in AppDelegate.
        .lineLimit(1)
        // RULE 2 (from PopoverMainView): all rows use .padding(.horizontal, 12).
        // Do not change this without changing every other row's padding too.
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // ── CPU segment ──────────────────────────────────────────────────────────
    //
    // Format: "CPU [bar] 20.1%"
    // Color:  usageColor on cpuPct (0–100)
    // "%.1f%%" gives one decimal place, e.g. "20.1%" — matches ci-dash.py
    //   `f"{cpu:4.1f}%"` formatting.

    private var cpuSegment: some View {
        HStack(spacing: 4) {
            Text("CPU").font(.caption2).foregroundColor(.secondary)
            bar(fraction: stats.cpuPct / 100, color: usageColor(pct: stats.cpuPct))
            Text(String(format: "%.1f%%", stats.cpuPct))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(usageColor(pct: stats.cpuPct))
        }
    }

    // ── MEM segment ──────────────────────────────────────────────────────────
    //
    // Format: "MEM [bar] 7.2/16.0GB"
    // usedPct is recomputed here from raw GB values (not stored in SystemStats)
    // to keep SystemStats a pure data bag with no view logic.
    // Color:  usageColor on usedPct.
    // "%.1f/%.1fGB" matches ci-dash.py `f"{mu:.1f}/{mt:.1f}GB"` format.

    private var memSegment: some View {
        let usedPct = stats.memTotalGB > 0
            ? (stats.memUsedGB / stats.memTotalGB) * 100
            : 0
        return HStack(spacing: 4) {
            Text("MEM").font(.caption2).foregroundColor(.secondary)
            bar(fraction: usedPct / 100, color: usageColor(pct: usedPct))
            Text(String(format: "%.1f/%.1fGB", stats.memUsedGB, stats.memTotalGB))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(usageColor(pct: usedPct))
        }
    }

    // ── DISK segment ─────────────────────────────────────────────────────────
    //
    // Format: "DISK [bar] 335/460GB (126GB 27%)"
    // usedPct drives both the bar fill AND the color — matches ci-dash.py:
    //   dp = (du / dt * 100); dc = R if dp > 85 else Y if dp > 60 else G
    // At 335/460 GB: dp = 72.8 % → yellow, matching the terminal dashboard.
    //
    // WHY Int() for GB values?
    //   At disk scale (hundreds of GB) the fractional part is irrelevant noise
    //   and wastes horizontal space. "335/460GB" is more readable than
    //   "335.2/460.0GB". The free % still has sub-1% precision via rounding.
    //
    // WHY diskFreePct from SystemStats and not recomputed here?
    //   diskFreePct is (freeGB / totalGB) × 100.  It could be recomputed here
    //   but is stored in the model so the label and any future color-on-free
    //   logic both read the same pre-computed value without risk of drift.

    private var diskSegment: some View {
        let usedPct = stats.diskTotalGB > 0
            ? (stats.diskUsedGB / stats.diskTotalGB) * 100
            : 0
        let color = usageColor(pct: usedPct)
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

    // ── Bar helper ───────────────────────────────────────────────────────────
    //
    // Renders a small progress bar: dim background track + colored fill overlay.
    //
    // WHY GeometryReader + ZStack instead of ProgressView?
    //   ProgressView's style and sizing is platform-controlled and inconsistent
    //   across macOS versions.  This ZStack approach gives us exact pixel control.
    //
    // WHY fixed .frame(width: 16, height: 5)?
    //   The bar must not grow with available space — doing so would cause DISK's
    //   label to be truncated.  Fixed size keeps the layout deterministic.
    //
    // `fraction` is clamped to 0…1 so overflowing values (e.g. 101% CPU from a
    //  delta glitch) don't cause the fill rect to exceed the track width.

    private func bar(fraction: Double, color: Color) -> some View {
        GeometryReader { _ in
            ZStack(alignment: .leading) {
                // Track: dim background
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.primary.opacity(0.1))
                // Fill: colored overlay scaled by fraction
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 16 * max(0, min(1, fraction)))
            }
        }
        .frame(width: 16, height: 5)
    }

    // ── Color helper ─────────────────────────────────────────────────────────
    //
    // Mirrors ci-dash.py's color logic for CPU, MEM, and DISK:
    //   cc = R if cpu > 85 else Y if cpu > 60 else G
    //   mc = R if mp  > 85 else Y if mp  > 60 else G
    //   dc = R if dp  > 85 else Y if dp  > 60 else G   ← DISK uses used%, same rule
    //
    // Thresholds rationale:
    //   > 85 % = danger (red)    — system under heavy load, CI may fail
    //   > 60 % = warning (yellow) — elevated, worth watching
    //   ≤ 60 % = nominal (green)  — plenty of headroom
    //
    // All three metrics use the same thresholds for visual consistency and
    // because they were copied directly from ci-dash.py where they are the same.

    private func usageColor(pct: Double) -> Color {
        if pct > 85 { return .red }
        if pct > 60 { return .yellow }
        return .green
    }
}
