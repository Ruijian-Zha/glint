# Proposal — Drag-resizable left sidebar (persisted width)

**Author:** Ruijian · **Date:** 2026-06-18 · **Repo:** `Ruijian-Zha/glint` (fork)
**Status:** proposal + research complete (code-verified). Pending: pick a handle variation → implement → rebuild.

## TL;DR

The left sidebar is a **hardcoded `frame(width: 244)`** (`ContentView.swift:23`) in a custom `HStack`,
with a purely decorative 1px hairline (`:26`) — **no resize at all**, so long cwd paths hide the
project name. Fix: make the width a **persisted `store.sidebarWidth`** and turn the seam into a real
**drag handle**, reusing the app's *own* pane-splitter idiom.

- **Reuse, don't invent:** `PaneTreeView.swift:53-132` already resizes panes with a transparent grab
  strip + `NSCursor.resizeLeftRight.push()/pop()` + a drag-base snapshot. The sidebar handle mirrors it.
- **~30 lines, low risk:** keeps the collapse animation (`ContentView.swift:28,56`), the flat-seam
  aesthetic, and the floating-header layout untouched.
- **No new entitlement, macOS 14-safe** (`NSCursor.resizeLeftRight` since 10.0; *not* `.pointerStyle`,
  which is macOS 15+ and the repo already guards it).
- **Pick a handle variation** (below). Recommended: **A** (clean) — but **B** (grip dots) if
  discoverability is the priority (you said it wasn't obvious it could be dragged).

---

## 1. Root cause (verified)

```swift
// ContentView.swift:22-28
SidebarView()
    .frame(width: 244)                       // ← hardcoded, not resizable
    .background(Theme.bgPane)
    .overlay(alignment: .trailing) {
        Rectangle().fill(Color.white.opacity(0.045)).frame(width: 1)  // ← decorative only
    }
    .transition(.move(edge: .leading).combined(with: .opacity))
```
No `NavigationSplitView`/`HSplitView`/`NSSplitView` anywhere → nothing gives a draggable divider.

## 2. Approach — custom handle (A), not NSSplitView (B)

| Approach | Verdict |
|---|---|
| **A. Interactive handle + persisted width** (replace the decorative hairline) | ✅ **Recommended** — mirrors the proven pane splitter, tiny diff, keeps collapse/seam/header layout |
| B. Rearchitect into `NSSplitView`/`HSplitView` | ❌ Rips out the working `sidebarCollapsed` animated transition, the flat-fill seam, and the floating-header overlay — large, risky, for one divider |
| C. AppKit `NSView` tracking-area handle | ➖ Most precise cursor mgmt, but over-engineered; the SwiftUI `.onHover`+`NSCursor` path already ships on the pane splitter |

**Cursor:** `NSCursor.resizeLeftRight.push()/pop()` via `.onHover` (exactly `PaneTreeView.swift:88-95`).
macOS 14-safe. Do **not** use `.pointerStyle(...)` (macOS 15+; the repo guards it in `arrowPointer()`).

## 3. Implementation (recommended variation A)

### 3.1 `WorkspaceStore.swift` — persisted width (mirrors `glassEffect` idiom, ~:480)

```swift
/// Width of the workspace sidebar in points. Drag-resizable via the seam
/// handle in ContentView; clamped to [min,max]. Default 244 = the old frame.
@Published var sidebarWidth: Double = {
    (UserDefaults.standard.object(forKey: "glint.sidebarWidth") as? Double) ?? 244
}() {
    didSet { UserDefaults.standard.set(sidebarWidth, forKey: "glint.sidebarWidth") }
}
static let defaultSidebarWidth: Double = 244
static let minSidebarWidth: Double = 200
static let maxSidebarWidth: Double = 460
```
> Use `object(forKey:) as? Double` (not `double(forKey:)`, which returns `0.0` when unset → would
> collapse the sidebar on first launch). Same precaution `terminalFontSize` takes.

### 3.2 `ContentView.swift` — drive width from the store + real handle

```swift
SidebarView()
    .frame(width: CGFloat(store.sidebarWidth))      // was: .frame(width: 244)
    .background(Theme.bgPane)
    .overlay(alignment: .trailing) { SidebarResizeHandle() }   // was: decorative Rectangle
    .transition(.move(edge: .leading).combined(with: .opacity))
```

```swift
private struct SidebarResizeHandle: View {
    @EnvironmentObject var store: WorkspaceStore
    @State private var dragBaseWidth: Double?     // width at drag start (track cursor, don't compound)
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .trailing) {
            Rectangle()                            // the seam hairline — brightens/thickens on hover
                .fill(Color.white.opacity(hovering ? 0.18 : 0.045))
                .frame(width: hovering ? 2 : 1)
                .animation(.easeOut(duration: 0.12), value: hovering)
            Color.clear                            // wide transparent grab strip on the seam
                .frame(width: 9).contentShape(Rectangle()).offset(x: 4)
                .onHover { inside in
                    hovering = inside
                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let base = dragBaseWidth ?? store.sidebarWidth
                            if dragBaseWidth == nil { dragBaseWidth = base }
                            store.sidebarWidth = min(max(base + Double(v.translation.width),
                                WorkspaceStore.minSidebarWidth), WorkspaceStore.maxSidebarWidth)
                        }
                        .onEnded { _ in dragBaseWidth = nil }
                )
                .onTapGesture(count: 2) {          // double-click → reset to default
                    withAnimation(.easeOut(duration: 0.18)) {
                        store.sidebarWidth = WorkspaceStore.defaultSidebarWidth
                    }
                }
        }
    }
}
```

**Clamp 200–460, default 244.** Below ~200 the QuotaSection + card status lines truncate; 460 lets a
full `~/…/Github/work_os` segment show without eating the terminal grid on a 1280-wide window.

## 4. Edge cases (all handled)

- **Collapse (⌘/):** handle lives inside `if !store.sidebarCollapsed`, so it vanishes with the sidebar
  — no conflict. Keep collapse a separate concept (no collapse-by-dragging-to-zero).
- **Live drag isn't animated:** `ContentView`'s `.animation(…, value: store.sidebarCollapsed)` is
  value-scoped to `sidebarCollapsed`, so width changes track the cursor 1:1. Don't add `sidebarWidth`
  to any `.animation(value:)`.
- **Card reorder gesture:** no conflict — the handle is a sibling strip on the seam, outside card hit
  areas (same as the pane splitter coexisting with pane content).
- **Double-click-to-reset:** standard divider affordance; the only animated path.

## 5. UX variations — pick one (`tmp/sidebar-resize/preview.html`)

| Pick | Handle look | Discoverability | Note |
|---|---|---|---|
| **A** ✅ clean | invisible 1px → thickens+brightens on hover | medium | byte-identical at rest; matches the pane divider exactly |
| **B** 👀 discoverable | always-visible faint **grip dots** on the seam | high | advertises "draggable" at rest — best fit for *"didn't know I could drag it"* |
| **C** minimal | no visual change ever; only the cursor flips | low | most faithful to the flat-seam aesthetic; least discoverable |
| **D** power | A + magnetic **snap-to-244** detent + double-click reset | medium | nicest for frequent resizers; most tuning, mild over-engineering |

All four: persisted width, clamp 200–460, double-click-to-reset, `NSCursor.resizeLeftRight`.

**Recommendation:** **A** for cleanliness; **B** if you want the edge to *show* it's draggable (matches
your complaint). Both are the same mechanic — only the resting visual differs.

## 6. Build & reinstall
Already wired: `tmp/cursor-button/build-and-install.sh` rebuilds + reinstalls (Xcode 16.2, Glass patch
applies). Same one-shot flow as the Cursor-button feature.
