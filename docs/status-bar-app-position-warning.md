# Definitive Guide: Preventing Side-Jumping in a macOS Status Bar Popover (NSPopover + SwiftUI)

> **Written for:** Any developer (human or AI) touching `AppDelegate.swift`, `PopoverView.swift`, or any sizing/frame/contentSize code in this project.  
> **Read this entire document before writing a single line.**

---

## 1. Why the Jump Happens — The Root Cause

`NSPopover` calculates its anchor position (the X/Y origin relative to the status bar button) at the moment `contentSize` is set or changes. **Any change to `contentSize` — including height-only changes — causes macOS to fully re-anchor the popover from scratch.** The re-anchor uses the current `NSStatusBarButton` frame for reference, but because the popover window has already moved on screen, the new origin is computed incorrectly and the popover flies to the wrong position (typically the far left of the screen).

**This is an AppKit constraint, not a bug you can work around with creative layout.** There is no API to change height without also triggering a re-anchor. The only escape is to prevent `contentSize.width` from ever changing, and to prevent `contentSize` from changing *at all* while the popover is visible to the user.

---

## 2. The Two Symptoms and What Causes Each

### Symptom A — Left Jump 🔴
The popover flies to the far left of the screen when opened or when data updates.

**Triggered by any of the following:**
- `popover.contentSize` is set manually anywhere in code
- `hc.sizingOptions = .preferredContentSize` is used AND any nav state reports a different ideal width than the others
- `hc.sizingOptions = .preferredContentSize` is used AND KVO/observers update `contentSize` in response to height changes
- `.frame(width: 340)` is used instead of `.frame(idealWidth: 340)` on the root view (they are NOT equivalent — see §4)
- `popover.performClose()` + `popover.show()` is called for in-app navigation (close/reopen triggers a full re-anchor from `show()`)
- `contentSize` is mutated inside a polling callback / `onChange` handler (fires while popover is visible)
- `hc.view.setFrameSize()` is called outside of a deliberate user-initiated navigation function

### Symptom B — Empty Black Space / Clipped Content 🔴
The popover is taller than its content (large empty void at bottom), or shorter (content clipped).

**Triggered by any of the following:**
- `popover.contentSize.height` is hardcoded to a fixed value that does not match worst-case content
- `.frame(height: X)` is added directly to the root `VStack`/`Group` in `PopoverView`
- `jobListView` (or equivalent dynamic list) is wrapped in a `ScrollView` — `ScrollView` reports infinite preferred height to SwiftUI's layout system, making the popover enormous or unpredictable
- `fixedSize(horizontal: false, vertical: true)` is removed from the dynamic list view
- `hc.sizingOptions` is changed away from `.preferredContentSize` (NSPopover stops tracking SwiftUI height → falls back to fixed size → empty space or clipping)

---

## 3. The Oscillation Trap (How Every Fix Breaks the Other)

This project has cycled through the following loop 15+ times across 25+ commits:

```
1. Symptom B reported (empty space or clipping)
2. Developer/AI tries to fix height → introduces dynamic resize in onChange or KVO
3. Symptom A triggered (left jump on every data poll)
4. Developer/AI removes dynamic resize → reverts to fixed contentSize constant
5. Fixed constant is wrong for current content → Symptom B returns
6. Repeat from step 2
```

The loop exists because fixing B *appears* to require dynamic height (which changes `contentSize`) and fixing A *appears* to require stable `contentSize`. These appear contradictory. **They are not — if you use `idealWidth` correctly.**

---

## 4. The Only Correct Solution

These constraints must ALL be true simultaneously. Violating any single one introduces a regression.

### Choose One Architecture — Do Not Mix Them

---

#### Architecture 1 — Fully Dynamic Height (SwiftUI-driven)

Use this when popover height must fit content dynamically (variable number of rows, no fixed layout).

```swift
// ✅ CORRECT — AppDelegate setup
hc.sizingOptions = .preferredContentSize
// ⛔ DO NOT set popover.contentSize anywhere — not here, not anywhere else
// ⛔ DO NOT add KVO or observers on preferredContentSize to then write contentSize
// ⛔ DO NOT change sizingOptions to [] or remove it
```

```swift
// ✅ CORRECT — PopoverView.swift root Group (wraps ALL navigation states)
Group {
    // mainView, detailView, and every other nav state here
}
.frame(idealWidth: 340)
// ⛔ NOT .frame(width: 340)              — layout constraint ≠ ideal size
// ⛔ NOT .frame(width: 340, height: 480) — fixes height → empty space
// ⛔ NOT .frame(minWidth: 340)            — does not pin ideal width
// ⛔ NOT removed                          — without it, ideal width is unconstrained → jump
```

```swift
// ✅ CORRECT — dynamic list view usage in PopoverView.swift
jobListView
    .fixedSize(horizontal: false, vertical: true)  // measure natural content height
    .frame(maxHeight: 480, alignment: .top)         // cap at 480pt, pin to top
// ⛔ DO NOT wrap jobListView in ScrollView
// ⛔ DO NOT remove fixedSize
// ⛔ DO NOT use .frame(height: 480) — that is fixed, not capped
```

```swift
// ✅ CORRECT — drill-down / detail view (e.g. JobStepsView.swift)
.frame(width: 340, height: 480)
// Width MUST match the idealWidth declared on the root Group.
// If this width differs, navigating here changes preferredContentSize.width → left jump.
// Fixed height is acceptable here because this view has its own ScrollView for content.
```

**Why `idealWidth` works:**  
`.frame(idealWidth: 340)` on the root `Group` instructs SwiftUI's layout system that the preferred/ideal width of this view is always 340pt. `NSHostingController` with `sizingOptions = .preferredContentSize` reads SwiftUI's *ideal* size (not its layout size) to publish as `preferredContentSize`. Because the root `Group` wraps every possible navigation state, `preferredContentSize.width` is always exactly 340, regardless of which screen is active. Height varies freely with content. Result: `contentSize.width` is stable → no re-anchor → no jump, while `contentSize.height` varies → no empty space.

---

#### Architecture 2 — Fixed Canonical Heights (AppKit-driven)

Use this when popover height is stable per-view (two or more known fixed heights, navigation between named views).

```swift
// ✅ CORRECT — AppDelegate canonical values
let fixedWidth:   CGFloat = 320   // NEVER dynamic
let mainHeight:   CGFloat = 390   // Tall enough for worst-case content. NEVER lower.
let detailHeight: CGFloat = 460   // Covers worst-case detail content. NEVER lower.
hc.sizingOptions = []             // NEVER .preferredContentSize

// ✅ CORRECT — the ONLY place contentSize is changed
private func navigate(to view: AnyView, height: CGFloat) {
    guard let popover, let hc else { return }
    let newSize = NSSize(width: fixedWidth, height: height)  // width ALWAYS fixedWidth
    hc.rootView = view
    hc.view.setFrameSize(newSize)
    NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0
        popover.contentSize = newSize
    }
}
// ⛔ navigate() is the ONLY function allowed to call setFrameSize or set contentSize
// ⛔ Do NOT call navigate() automatically — only on deliberate user tap
```

```swift
// ✅ CORRECT — onChange handler (data polling, every ~10s)
RunnerStore.shared.onChange = { [weak self] in
    self?.statusItem?.button?.image = makeStatusIcon(for: RunnerStore.shared.aggregateStatus)
    self?.observable.reload()
    // ⛔ NOTHING ELSE. No contentSize. No setFrameSize. No navigate(). Nothing.
}
```

```swift
// ✅ CORRECT — root VStack in PopoverMainView.swift
VStack(...) { ... }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
// ⛔ NEVER .frame(height: X) here — AppDelegate owns height, the view fills it
```

**Why `mainHeight = 390` (or your equivalent worst-case value):**  
The height must accommodate the maximum possible content (e.g. 3 job rows + 2 runner rows + all sections). Setting it lower clips content. Setting it to a computed dynamic value and applying that in `onChange` fires while the popover is visible → Symptom A. Accept minor empty space in sparse states — that is the correct trade-off.

---

## 5. Complete List of Forbidden Patterns

```swift
// ❌ Setting contentSize manually — anywhere, ever (Architecture 1)
popover.contentSize = NSSize(width: 340, height: 480)

// ❌ Setting contentSize in a polling callback / timer / onChange (both architectures)
RunnerStore.shared.onChange = { self?.popover.contentSize = ... }  // LEFT JUMP

// ❌ Setting contentSize with a dynamic width (both architectures)
popover.contentSize = NSSize(width: hc.view.fittingSize.width, ...)  // LEFT JUMP

// ❌ Changing sizingOptions to auto-resize (Architecture 2)
hc.sizingOptions = .preferredContentSize  // with fixed-height arch → jump on layout pass

// ❌ Removing sizingOptions line entirely (Architecture 1)
// → NSPopover stops tracking SwiftUI height → fixed default size → empty space

// ❌ Using .frame(width: 340) instead of .frame(idealWidth: 340) (Architecture 1)
// → Layout width ≠ ideal width; preferredContentSize.width becomes unpredictable → jump

// ❌ Using .frame(width: 340, height: 480) on the root Group (Architecture 1)
// → Fixes both dimensions; height never varies → empty space

// ❌ Removing .frame(idealWidth: 340) entirely (Architecture 1)
// → Ideal width becomes unconstrained → jump

// ❌ KVO / observers on preferredContentSize that write back to contentSize
// → Any contentSize write (even height-only) triggers full NSPopover re-anchor → jump

// ❌ Wrapping the dynamic list view in ScrollView (Architecture 1)
// → ScrollView reports infinite preferred height → enormous popover or unpredictable size

// ❌ Adding .frame(height: X) to PopoverMainView's root VStack (both architectures)
// → View defines its own height, fights AppDelegate's contentSize → height mismatch

// ❌ Calling performClose() + show() for in-app navigation (both architectures)
// → show() re-anchors from scratch → LEFT JUMP

// ❌ Calling setFrameSize() or contentSize outside navigate() (Architecture 2)
// → Any call while popover is visible → LEFT JUMP

// ❌ Changing detail view frame width away from idealWidth (Architecture 1)
// → Navigating there changes preferredContentSize.width → LEFT JUMP

// ❌ Using .fixedSize(horizontal: true, vertical: true) on root view (both architectures)
// → Forces SwiftUI to report unconstrained ideal width → jump

// ❌ Lowering mainHeight below the worst-case content budget (Architecture 2)
// → Content is clipped at maximum state
```

---

## 6. The `.frame(width:)` vs `.frame(idealWidth:)` Distinction

This distinction is the most common source of regression. They are **not interchangeable** in this context.

| Modifier | What it affects | What NSHostingController reads |
|---|---|---|
| `.frame(width: 340)` | SwiftUI **layout width** — constrains the view's rendered size during layout | Does **not** guarantee `preferredContentSize.width = 340`. Different nav states may report different ideal widths. |
| `.frame(idealWidth: 340)` | SwiftUI **ideal/preferred width** — the size the view *wants* to be when unconstrained | `NSHostingController.preferredContentSize.width` reads this directly. Always 340 regardless of nav state. |

The counterintuitive truth: **`idealWidth` is the correct modifier for NSPopover sizing. `width` is not.**

---

## 7. Pre-Commit Checklist

Run through this mentally before every push that touches any sizing, layout, or navigation code:

**Regression A (Left Jump) guards:**
- [ ] Is `popover.contentSize` set anywhere outside of `navigate()`? → **Regression A**
- [ ] Is `hc.view.setFrameSize` called anywhere outside of `navigate()`? → **Regression A**
- [ ] Is `sizingOptions` set to anything other than the canonical value for this architecture? → **Regression A**
- [ ] Is there any KVO / observer writing back to `contentSize`? → **Regression A**
- [ ] Is `performClose()` + `show()` called for navigation (not toggle)? → **Regression A**
- [ ] Does `onChange` / any polling callback touch sizing? → **Regression A**
- [ ] Is the root `Group`/`VStack` in `PopoverView` using `.frame(idealWidth:)` (Arch 1) or `.frame(maxWidth: .infinity ...)` (Arch 2)? → If wrong, **Regression A**
- [ ] Does the detail/drill-down view frame width match the root `idealWidth`? → **Regression A**

**Regression B (Height Mismatch) guards:**
- [ ] Is `sizingOptions` correctly set for the chosen architecture? If `[]` with no navigate() → **Regression B**
- [ ] Is `.frame(height: X)` added to `PopoverMainView`'s root? → **Regression B**
- [ ] Is `mainHeight` below the worst-case pixel budget? → **Regression B**
- [ ] Is `jobListView` wrapped in `ScrollView`? → **Regression B**
- [ ] Is `fixedSize(horizontal: false, vertical: true)` still on `jobListView`? → If removed, **Regression B**

**General guards:**
- [ ] Did `ActiveJob`'s `init` change? → grep all 3 callsites: `grep -rn 'ActiveJob(' Sources/`
- [ ] Was the version string bumped in `PopoverMainView.swift`?
- [ ] Tested: open popover → close → open again → no left jump?
- [ ] Tested: empty state (0 jobs) AND full state (max jobs + runners) → height fits both?

---

## 8. Architecture Decision Reference

| Scenario | Architecture 1 (SwiftUI-driven) | Architecture 2 (AppKit-driven) |
|---|---|---|
| Content height is variable (list with 0–N rows) | ✅ | ❌ |
| Content height is fixed per named view | ✅ possible | ✅ simpler |
| Navigation between views with different heights | ✅ (idealWidth handles it) | ✅ (navigate() handles it) |
| Data polling that updates content | ✅ (SwiftUI redraws; contentSize never touched) | ✅ (onChange never touches sizing) |
| Drill-down views with their own ScrollView | ✅ (fixed frame on detail view is fine) | ✅ |

**Do not mix architectures.** Never use `sizingOptions = .preferredContentSize` AND manually set `contentSize` in the same codebase path.

---

## 9. Canonical Values for This Project

Update this table when canonical values change — and update it *only here*.

```swift
// Architecture in use: [FILL IN: Architecture 1 or Architecture 2]

// AppDelegate.swift
fixedWidth:    320 or 340     // The ONLY allowed width — never dynamic
mainHeight:    390            // Worst-case main view height — never lower
detailHeight:  460            // Worst-case detail view height — never lower
sizingOptions: []             // OR .preferredContentSize — depends on architecture

// PopoverView.swift / PopoverMainView.swift — root modifier
// Architecture 1: .frame(idealWidth: 340)
// Architecture 2: .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

// All section rows — uniform horizontal padding
.padding(.horizontal, 12)

// Job rows — vertical padding
.padding(.vertical, 3)

// Runner rows — vertical padding
.padding(.vertical, 5)

// Header
.padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
```

If any value in your file differs from this table, **that is the regression** — not something to be "improved".

---

*References: issues #51, #52, #53, #54, #57 — regression history on feat/job-detail-steps branch.*

```prompt to create this md file
we are suffering from major regression with side jumping app when we cahnge sizing. please read these [https://github.com/eoncode/runner-bar/issues/51%20and%20https://github.com/eoncode/runner-bar/issues/54%20and%20https://github.com/eoncode/runner-bar/issues/321%20and%20https://github.com/eoncode/runner-bar/issues/52%20and%20https://github.com/eoncode/runner-bar/issues/57](https://github.com/eoncode/runner-bar/issues/51%20and%20https://github.com/eoncode/runner-bar/issues/54%20and%20https://github.com/eoncode/runner-bar/issues/321%20and%20https://github.com/eoncode/runner-bar/issues/52%20and%20https://github.com/eoncode/runner-bar/issues/57) and make a definitive guide how to avoid side jumping issues in statusbar app. also read the internet on this topic. as this app cant be the only one struggling with this. return a markdown bloack with the definitive guide.
```
