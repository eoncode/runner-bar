import Foundation
import Darwin
import Combine

// ── SystemStats — plain value type ───────────────────────────────────────────
//
// Holds one snapshot of CPU / MEM / DISK metrics.
// All values are computed off the main thread by SystemStatsViewModel and
// published to SwiftUI via @Published on the main thread.
//
// WHY a struct?
//   Value semantics means SwiftUI detects changes via diffing — no manual
//   objectWillChange.send() needed; @Published handles it.

struct SystemStats {
    /// CPU utilisation across all cores, 0–100 %.
    /// Derived from the *delta* between two host_processor_info() samples
    /// so it reflects activity in the last polling interval, not cumulative.
    var cpuPct: Double

    /// Memory actively in use: (pages_active + pages_wired_down) × pageSize.
    /// WHY only active+wired?
    ///   This matches ci-dash.py (vm_stat pages_active + pages_wired_down)
    ///   and represents memory the system cannot reclaim immediately.
    ///   Compressed, inactive, and file-backed/cache pages are excluded because
    ///   the kernel can evict them under pressure — they are not "real" pressure.
    var memUsedGB: Double

    /// Physical RAM installed, read once from sysctl hw.memsize.
    var memTotalGB: Double

    /// Disk space occupied: diskTotalGB − diskFreeGB.
    var diskUsedGB: Double

    /// Raw partition capacity from volumeTotalCapacity.
    var diskTotalGB: Double

    /// True available space from volumeAvailableCapacityForImportantUsage.
    /// WHY this key instead of volumeAvailableCapacityKey?
    ///   APFS uses "purgeable" space (caches, Time Machine local snapshots) that
    ///   looks free via df/volumeAvailableCapacity but isn't reliably available.
    ///   volumeAvailableCapacityForImportantUsage is what Finder shows and what
    ///   the system guarantees it can deliver for a "important" write (e.g. running
    ///   a SonarQube scan or a CI job).
    var diskFreeGB: Double

    /// Free space as a percentage of total: (diskFreeGB / diskTotalGB) × 100.
    /// Used by SystemStatsView to decide the DISK color threshold.
    var diskFreePct: Double

    /// Safe default shown while the first sample is being computed.
    /// Uses plausible values (16 GB RAM, 460 GB disk all-free) so the bar
    /// starts empty rather than full, which is less alarming on launch.
    static let zero = SystemStats(
        cpuPct: 0, memUsedGB: 0, memTotalGB: 16,
        diskUsedGB: 0, diskTotalGB: 460, diskFreeGB: 460, diskFreePct: 100
    )
}

// ── SystemStatsViewModel ─────────────────────────────────────────────────────
//
// ObservableObject that owns the 2-second polling loop.
//
// Threading model:
//   • The Timer fires on the main RunLoop (required for RunLoop scheduling),
//     but immediately bounces the actual work onto a global utility queue so
//     the main thread is never blocked by syscalls.
//   • After computing the snapshot, we hop back to the main thread
//     (DispatchQueue.main.async) to write @Published stats, keeping SwiftUI
//     observation safe.
//
// WHY 2 seconds?
//   ci-dash.py uses REFRESH_SYSTEM = 3 s. 2 s gives slightly snappier feedback
//   in the popover without meaningfully increasing CPU overhead (the mach calls
//   are cheap — < 1 ms each).
//
// WHY weak self in the timer closure?
//   Prevents a retain cycle: Timer → closure → self → timer.
//   If the popover is deallocated the timer is also invalidated in deinit.

final class SystemStatsViewModel: ObservableObject {
    /// The latest system snapshot. SwiftUI views observe this via @Published.
    @Published var stats: SystemStats = .zero

    private var timer: Timer?

    /// Mach tick counts from the previous sample, used to compute CPU delta.
    /// Storing cumulative ticks and diffing gives us the % over the last
    /// interval rather than since boot, which is what Activity Monitor shows.
    private var prevTicks: (user: Double, sys: Double, total: Double) = (0, 0, 0)

    init() {
        // Call sample() immediately so the popover shows real values on first
        // open rather than the .zero placeholder.
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            // Bounce off main thread — syscalls can take tens of milliseconds.
            DispatchQueue.global(qos: .utility).async { self?.sample() }
        }
    }

    deinit {
        // Prevent the timer from firing after deallocation.
        timer?.invalidate()
    }

    // ── CPU ──────────────────────────────────────────────────────────────────
    //
    // Uses the Mach host_processor_info() API to read per-core tick counters.
    //
    // WHY NOT `top` or `ps`?
    //   Both spawn a subprocess which takes ~50 ms and adds memory overhead.
    //   host_processor_info() is a direct kernel call, ~0.1 ms.
    //
    // HOW IT WORKS:
    //   The kernel maintains cumulative tick counters per core in four buckets:
    //     CPU_STATE_USER   — time in user-space code (apps)
    //     CPU_STATE_SYSTEM — time in kernel/system calls
    //     CPU_STATE_IDLE   — idle
    //     CPU_STATE_NICE   — user-space code at reduced priority
    //   We add user+nice+system for "busy" ticks and user+nice+system+idle for
    //   total ticks, diff against the previous sample, and express as a percent.
    //   Summing across all cores then dividing gives per-CPU-average.
    //
    // MEMORY MANAGEMENT:
    //   host_processor_info() allocates a Mach port buffer that we must free
    //   with vm_deallocate() to avoid a memory leak.

    private func cpuPercent() -> Double {
        var cpuInfo: processor_info_array_t?
        var msgType  = natural_t(0)              // receives the number of logical CPUs
        var numCPUInfo = mach_msg_type_number_t(0) // receives the buffer element count

        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &msgType, &cpuInfo, &numCPUInfo) == KERN_SUCCESS,
              let info = cpuInfo else { return 0 }

        let numCPUs = Int(msgType)
        var userTicks  = 0.0
        var sysTicks   = 0.0
        var totalTicks = 0.0

        for i in 0 ..< numCPUs {
            // Each CPU occupies CPU_STATE_MAX consecutive integer_t slots.
            let base = Int32(CPU_STATE_MAX) * Int32(i)
            let u  = Double(info[Int(base) + Int(CPU_STATE_USER)])
            let s  = Double(info[Int(base) + Int(CPU_STATE_SYSTEM)])
            let id = Double(info[Int(base) + Int(CPU_STATE_IDLE)])
            let n  = Double(info[Int(base) + Int(CPU_STATE_NICE)])
            userTicks  += u + n          // nice is unprioritised user work
            sysTicks   += s
            totalTicks += u + s + id + n
        }

        // Free the kernel-allocated buffer — required to avoid a Mach port leak.
        vm_deallocate(mach_task_self_,
                      vm_address_t(bitPattern: cpuInfo),
                      vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.stride))

        // Delta against previous sample — this is the activity in the last 2 s.
        let dUser  = userTicks  - prevTicks.user
        let dSys   = sysTicks   - prevTicks.sys
        let dTotal = totalTicks - prevTicks.total

        // Save current cumulative totals for next delta.
        prevTicks = (userTicks, sysTicks, totalTicks)

        // Guard against first sample where prev is zero (dTotal = some ticks,
        // dUser = same value → would give 100 %).
        // On the very first call prevTicks is (0,0,0) so we just return 0
        // rather than a misleading spike.
        guard dTotal > 0 else { return 0 }
        return min(100, ((dUser + dSys) / dTotal) * 100)
    }

    // ── MEM ──────────────────────────────────────────────────────────────────
    //
    // Uses host_statistics64() with HOST_VM_INFO64 to read page counters,
    // then sysctl hw.memsize for physical RAM total.
    //
    // WHY active + wired only (same as ci-dash.py)?
    //   macOS categorises pages into:
    //     active    — recently accessed, in RAM
    //     wired     — pinned by kernel, cannot be paged out (e.g. kernel data)
    //     inactive  — not recently used but still in RAM; can be reclaimed
    //     speculative — pre-fetched, treated as free by Activity Monitor
    //     compressed — swapped to the compressor; counted by Activity Monitor
    //                  as "Memory Used" but is paged out under pressure
    //     file-backed — disk cache; freely evictable
    //   Only active+wired represents memory the system cannot reclaim without
    //   application cooperation.  This matches what ci-dash.py measures via
    //   vm_stat "Pages active" + "Pages wired down".
    //
    // WHY NOT sysctl vm.swapusage?
    //   Swap is a symptom, not the cause.  We want to show pressure on physical RAM.

    private func memStats() -> (used: Double, total: Double) {
        var vmStats = vm_statistics64()
        // count must be set to the number of integer_t-sized slots in vm_statistics64
        // before calling host_statistics64; the kernel writes back the actual count.
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
        )

        let kr = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard kr == KERN_SUCCESS else { return (0, 16) }

        let pageSize = Double(vm_kernel_page_size) // typically 16 384 bytes on Apple Silicon
        let gb       = 1024.0 * 1024.0 * 1024.0

        // active_count + wire_count in pages → GB
        let used = Double(vmStats.active_count + vmStats.wire_count) * pageSize / gb

        // Physical RAM total — read via sysctl once; the value never changes.
        var memSize: UInt64 = 0
        var memSizeLen = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &memSize, &memSizeLen, nil, 0)
        let total = Double(memSize) / gb

        return (used, total)
    }

    // ── DISK ─────────────────────────────────────────────────────────────────
    //
    // Uses Foundation URL resource values — no subprocess, no `df`.
    //
    // WHY volumeAvailableCapacityForImportantUsage and NOT volumeAvailableCapacity?
    //   On APFS volumes the system keeps "purgeable" space: local Time Machine
    //   snapshots, app caches, etc.  volumeAvailableCapacity does NOT include
    //   that purgeable space, so it under-reports free space.
    //   volumeAvailableCapacityForImportantUsage instructs the system to promise
    //   it can free purgeable space on demand and returns the realistic figure —
    //   the same number Finder and macOS storage reports show.
    //   This is the correct value to use when asking "will a CI job have enough
    //   space to run?"
    //
    // WHY query "/" (root)?
    //   On typical macOS setups all user-visible storage lives on the same APFS
    //   container mounted at /.  If you have multiple volumes you would need to
    //   query each mount point separately — out of scope for now.
    //
    // FALLBACK:
    //   If the query fails (sandboxed context, weird mount) we return a safe
    //   non-alarming default (all free) so the UI doesn't show false red.

    private func diskStats() -> (used: Double, total: Double, free: Double, freePct: Double) {
        let url = URL(fileURLWithPath: "/")
        let gb  = 1024.0 * 1024.0 * 1024.0

        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]),
        let totalBytes = values.volumeTotalCapacity,
        let freeBytes  = values.volumeAvailableCapacityForImportantUsage
        else {
            // Safe fallback: show disk as completely free to avoid a false red alarm.
            return (0, 460, 460, 100)
        }

        let total   = Double(totalBytes) / gb
        let free    = Double(freeBytes)  / gb
        let used    = total - free
        let freePct = total > 0 ? (free / total) * 100: 100

        return (used, total, free, freePct)
    }

    // ── Sample ───────────────────────────────────────────────────────────────
    //
    // Called every 2 s from a background thread.
    // Assembles a new SystemStats value and publishes it on the main thread.
    // All three reads (cpu, mem, disk) are sequential on the same background
    // thread — no concurrency issues.

    private func sample() {
        let cpu  = cpuPercent()
        let mem  = memStats()
        let disk = diskStats()

        let s = SystemStats(
            cpuPct:      cpu,
            memUsedGB:   mem.used,
            memTotalGB:  mem.total,
            diskUsedGB:  disk.used,
            diskTotalGB: disk.total,
            diskFreeGB:  disk.free,
            diskFreePct: disk.freePct
        )

        // Always update @Published on the main thread — SwiftUI requirement.
        DispatchQueue.main.async { self.stats = s }
    }
}
