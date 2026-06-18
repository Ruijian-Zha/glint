# Debug report — sidebar-resize "flicker / twitch" in the top chrome

**Author:** Ruijian · **Date:** 2026-06-18 · **Repo:** `Ruijian-Zha/glint` (fork)
**Symptom:** dragging the new sidebar resize handle makes the top chrome (toolbar
islands / header, sidebar top) **twitch/convulse** ("上面在抽搐"). A first fix
(SwiftUI re-render isolation) reduced but did **not** eliminate it.

## TL;DR

The twitch is **not** a re-render storm. It's the **sidebar width value oscillating
~10px frame-to-frame during the drag**, which jitters the whole layout (including the
header position). Root cause: the `DragGesture` used the **default local coordinate
space**, but the grab handle is anchored to the sidebar's trailing edge and **moves as
the sidebar resizes** → the local translation reference moves under the cursor → a
feedback loop. **Fix: `DragGesture(coordinateSpace: .global)`.** (The earlier re-render
isolation fix was correct and is kept.)

---

## Method — instrument + capture

Two failed capture attempts, then a working one (recorded so future debugging skips the dead ends):
- `log stream`/`log show --predicate 'eventMessage CONTAINS "[glint.flick]"'` → **nothing**.
  NSLog from this ad-hoc-signed, `open`-launched app did not surface in the unified log
  query (and a backgrounded `log stream` with a quoted predicate got mangled by the shell).
- **Working:** launch the binary directly with stderr redirected —
  `/Applications/Glint.app/Contents/MacOS/Glint > /tmp/glint-stderr.log 2>&1 &`. NSLog
  writes to stderr, captured cleanly.

Instrumentation: `let _ = { NSLog("[glint.flick] …") }()` at the top of `ContentView.body`,
`ResizableSidebar.body` (with `width=`), `ToolbarHeader.body`, and
`PaneSurfaceRepresentable.updateNSView`. Then one ~5s user drag.

## Data (one drag)

| Marker | Count during drag | Reading |
|---|---|---|
| `ResizableSidebar.body` | **497** | per-frame — expected (owns the drag `@State`) |
| `ContentView.body` | 10 | **not** per-frame |
| `ToolbarHeader.body` | 9 | **not** per-frame |
| `PaneSurfaceRepresentable.updateNSView` | 1 | once |

**Conclusion 1:** the prior re-render isolation fix works — the header/terminal are **not**
re-rendering per frame. So the twitch is not SwiftUI invalidation.

**Conclusion 2 (the smoking gun):** the `width=` values logged each frame **oscillate**:

```
356 → 343 → 352 → 339 → 348 → 334 → 344 → 329 → 339 → 322 → 336 → 318 → 332 → 314 …
… 318 → 307 → 318 → 306 → 319 → 306 → 318 → 306
```

The width bounces between a higher and a lower value (~10–12px apart) on alternating
frames. The sidebar literally changes width back and forth 60×/s → the HStack relayouts
each frame → the content area (and its top-aligned header overlay) shifts left/right each
frame → **visible twitch**.

## Root cause — drag-handle feedback loop (local coordinate space)

The handle:
```swift
Color.clear.frame(width: 9).offset(x: 4)
    .gesture(
        DragGesture(minimumDistance: 0)            // ← DEFAULT = .local coordinate space
            .onChanged { value in
                let base = dragBaseWidth ?? store.sidebarWidth
                if dragBaseWidth == nil { dragBaseWidth = base }
                dragWidth = clamp(base + Double(value.translation.width))
            }
        …
    )
```

The grab strip is `.overlay(alignment: .trailing)` on `SidebarView`, i.e. **anchored to the
sidebar's trailing edge**. When `dragWidth` changes, the sidebar resizes and the handle
**moves with the edge**. With the default **`.local`** coordinate space,
`value.translation` is measured relative to the gesture view's *own* frame — but that frame
just moved. So each frame:

1. cursor moves a little → translation grows → width grows →
2. handle moves right with the wider edge → cursor is now "behind" the handle in its new
   local space → next translation reads smaller → width shrinks →
3. handle moves left → translation reads larger again → …

→ a width oscillation that tracks the handle's own motion. ~10px amplitude ≈ the handle's
displacement per frame. Classic "the thing you're dragging moves, so local translation
feeds back."

## Fix

Measure the drag in **screen space**, which is fixed and immune to the handle moving:

```swift
DragGesture(minimumDistance: 0, coordinateSpace: .global)
```

`value.translation` then = (current global cursor) − (global cursor at drag start), a true
cursor displacement. `base + translation` is monotonic with the cursor → no oscillation,
no twitch.

Kept from the earlier fix (still correct and necessary):
- Live drag width in `ResizableSidebar`'s local `@State`, **not** the global `@Published`
  store (prevents the 60×/s `objectWillChange` storm; store is written once on drag end).
- `dragBaseWidth` snapshot so cumulative `translation` adds to a fixed base.

## Verification plan
Re-instrument-free build; drag; confirm the `width=` sequence is **monotonic** with cursor
direction (no alternating high/low) and the header no longer twitches.

## Cleanup
Remove the `[glint.flick]` NSLog markers from `ContentView.swift` (×3) and
`PaneSurfaceRepresentable.swift` (×1) before shipping.
