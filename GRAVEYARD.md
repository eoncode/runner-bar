# GRAVEYARD — Investigation Log

Branch: `fix/runner-json-bom-and-githuburl-casing`
Goal: `arm64 · macOS` subtitle appears on ALL local runners, not just one.

---

## What we know for certain

- `arm64 · macOS` does **NOT** come from the `.runner` file on disk.
- It comes from the GitHub API — specifically from the runner's labels (e.g. `["self-hosted", "macOS", "arm64"]`) fetched by `RunnerStatusEnricher`.
- `RunnerStatusEnricher` needs a valid `gitHubUrl` from the `.runner` JSON to know which API endpoint to call.

---

## Attempt 1 — BOM strip + CodingKey fix ✅ Partial success

**Hypothesis:** `gitHubUrl` was decoding as `nil` for ALL runners because:
1. The `.runner` file has a UTF-8 BOM (`0xEF 0xBB 0xBF`) that `JSONDecoder` chokes on silently.
2. The `CodingKey` was mapped to `"GitHubUrl"` (PascalCase) but the file contains `"gitHubUrl"` (camelCase).

**What we did:** Stripped BOM from raw `Data` before decoding. Fixed CodingKey to `"gitHubUrl"`.

**Result:** `psw-pwa-repo-runner-1` now shows `arm64 · macOS`. ✅  
`psw-org-runner` still does not. ❌

---

## Current hypothesis — `psw-org-runner` enrichment still failing

`psw-org-runner` is an **org-level runner**. Its `gitHubUrl` likely points to the org (`https://github.com/psw-pwa`) not a repo.

`RunnerStatusEnricher` may only handle repo-scoped URLs and silently skip org-scoped ones — meaning no API call is made for `psw-org-runner`, no labels returned, no subtitle.

**Next step:** Read `RunnerStatusEnricher.swift` (RunnerBarCore) to confirm whether org-scoped `gitHubUrl` values are handled. Fix if not.

---

## What has NOT been touched yet

- `RunnerStatusEnricher.swift` — not read, not changed
- The view layer rendering the subtitle — not confirmed which file
- `Runner.swift` / `RunnerStore.swift` — confirmed not the source of `arm64·macOS`, not changed

---

## Dead ends / wrong turns

- **CPU/MEM regression:** Suspected my commit caused it. Diff proved it did not — nothing in the metrics path was touched. CPU/MEM only shows on actively busy runners; both runners happened to be idle at screenshot time.
- **`.runner` file as source of arm64/macOS:** Incorrectly assumed this twice. Corrected: labels come from GitHub API via enricher, not disk.
- **`RunnerStore` architecture discussion:** Got sidetracked into a refactor discussion about Runner vs Scope separation. Not relevant to the immediate bug.

---

## Session 2 — Branch `fix/runner-json-bom-and-githuburl-casing` (2026-05-30)

### Build failures introduced by the branch

After pulling and building, the compiler emitted **15 errors** — all introduced by changes to `RunnerViewModel.swift`, `RunnerStore.swift`, `LocalRunnerStore.swift`, and `PanelMainView.swift` on the branch.

---

### Failure 1 — `RunnerViewModel.runners` wrong type ❌ → ✅ Fixed

**Root cause:** `@Published var runners` was declared as `[RunnerModel]` but `RunnerStore.runners` is `[Runner]` (the GitHub API struct from `RunnerBarCore`). The assignment `runners = store.runners` in `reload()` was a direct type mismatch.

**Confusion:** Two separate runner types exist in the codebase:
- `Runner` — GitHub API struct (`RunnerBarCore`). Has `.id: Int`, `.name: String`, `.busy: Bool`.
- `RunnerModel` — local runner struct (`RunnerBarCore`). Has `.id: String`, `.runnerName: String`, `.agentId: Int?`, `.isBusy: Bool`.

`RunnerViewModel` bridges both: `.runners: [Runner]` (from GitHub API) and `.localRunners: [RunnerModel]` (from `LocalRunnerStore`). The declaration was mistakenly set to `[RunnerModel]` for both.

**Fix:** `@Published var runners: [RunnerModel]` → `@Published var runners: [Runner]`.

---

### Failure 2 — `reload()` nonisolated but accesses `@MainActor` properties ❌ → ✅ Fixed

**Root cause:** `RunnerStore` and `LocalRunnerStore` are `@MainActor`-isolated. `RunnerViewModel.reload()` had no isolation annotation, making it `nonisolated` under Swift 6 strict concurrency. Every property access (`store.actions`, `store.jobs`, `store.runners`, `store.isRateLimited`, `store.rateLimitResetDate`, `localStore.runners`, `LocalRunnerStore.shared`, `RunnerStore.shared`) was a concurrency violation.

**Fix:** Added `@MainActor` to `func reload()`. Since `reload()` is always called from the display tick on the main thread anyway, this is the correct annotation — not `nonisolated`.

**Lesson:** When a function is a pure bridge between `@MainActor` stores and `@MainActor` `@Published` properties, it must itself be `@MainActor`. Leaving it unannotated is not safe under Swift 6.

---

### Failure 3 — `.isBusy` does not exist on `Runner` ❌ → ✅ Fixed

**Root cause:** `PanelMainView.activeLocalRunners` filtered `store.runners` (which is now correctly `[Runner]`) using `$0.isBusy`. But `Runner` has `.busy: Bool`, not `.isBusy`. `.isBusy` is a property of `RunnerModel` (the local runner type).

**Fix:** `.isBusy` → `.busy` in `PanelMainView.swift`.

**Lesson:** The `Runner` / `RunnerModel` naming asymmetry (`busy` vs `isBusy`) is a footgun. Worth aligning these at some point — either add a computed `var isBusy: Bool { busy }` to `Runner`, or rename consistently.

---

### Runtime log — healthy ✅

The `log stream` output (from the previously built binary) showed no errors:
- `LocalRunnerStore` loaded 4 runners correctly.
- `fetchRunners` returned HTTP 200 for both `psw-pwa/psw-pwa` (1 runner) and `eoncode/runner-bar` (2 runners).
- Rate limit healthy: ~4901–4909 remaining of 5000, `Retry-After: nil`.
- `RunnerMetrics` enrichment completed successfully (`cpu:1.1 mem:0.3`).
- All 8 `installPathMap` keys correctly populated across both scopes.

---

### Dead ends / wrong turns (Session 2)

- **Assumed `MainView.swift`:** The build log referenced `MainPanelMainView.swift` (old path). The actual file is `Views/Main/PanelMainView.swift`. Wasted a lookup on the wrong path.
- **`as! RunnerModel` cast:** The build log showed this as a note, which looked like an explicit forced cast in source. It was actually the compiler describing the type mismatch — no forced cast existed in the code.
