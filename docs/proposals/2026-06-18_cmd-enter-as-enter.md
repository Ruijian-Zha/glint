# Proposal — ⌘+Enter behaves as Enter (submit) in the terminal

**Author:** Ruijian · **Date:** 2026-06-18 · **Repo:** `Ruijian-Zha/glint` (fork)
**Status:** proposal — **feasible, ~15 lines.** Pending: implement → rebuild.

## Problem

A trackpad gesture (two-finger tap via BetterTouchTool) is bound to **⌘↩ (Cmd+Return)** to
"submit" in other terminals/agent UIs. In Glint that gesture does nothing — you have to press
Return manually. Goal: at the app level, **map ⌘+Enter → a plain Enter** so the gesture (and a
literal ⌘↩) submits the line / agent prompt.

## Why it's a no-op today (verified)

`GhosttySurfaceView.keyDown` (`GhosttySurfaceView.swift:922`) routes any Command-modified key
through ghostty as a *binding*:

```swift
let hasBindingMod = mods.contains(.control) || mods.contains(.command) || optionActsAsMeta(...)
if hasBindingMod || Self.isSpecialKey(event.keyCode) {
    let handled = sendKey(event, action: GHOSTTY_ACTION_PRESS, surface: s)  // ⌘+Return goes here
    if !handled { interpretKeyEvents([event]) }
}
```

Embedded ghostty has no useful `cmd+enter` binding (stock ghostty.app maps it to fullscreen via
its own menu, which we don't get when embedding), so ⌘+Return is swallowed with no CR reaching
the shell/agent → nothing submits. (keyCode 36 = Return, 76 = numpad Enter.)

Also relevant: an **unmodified** Return fires `.glintPaneReturnPressed`
(`GhosttySurfaceView.swift:969-974`), which `WorkspaceStore.handlePaneReturn`
(`:913-919`) uses to optimistically flip the pane's agent status (snappy sidebar "working"
state). ⌘+Enter should mirror this to feel identical to Enter.

## Recommended approach — intercept ⌘+Return in `keyDown` (Approach B)

Insert early in `keyDown` (after the ⌘V block, ~`:955`), before the `hasBindingMod` branch:

```swift
// ⌘+Return / ⌘+Enter → a plain Return. A trackpad gesture (BetterTouchTool
// two-finger tap) sends ⌘↩ to "submit", but embedded ghostty has no binding
// for it, so it's a dead key here. Re-dispatch it as a real Return so the
// gesture submits the line / agent prompt exactly like Enter does.
if (event.keyCode == 36 || event.keyCode == 76),
   mods.contains(.command),
   !mods.contains(.shift), !mods.contains(.option), !mods.contains(.control),
   !hasMarkedText() {                                   // don't hijack IME composition
    // Mirror the unmodified-Return side-effect so agent-status tracking fires.
    if let pk = paneKey {
        NotificationCenter.default.post(
            name: .glintPaneReturnPressed, object: nil, userInfo: ["pane": pk])
    }
    // Synthesize a Command-free Return and send it through the normal key path,
    // so ghostty emits the correct CR for the current terminal mode.
    if let plain = NSEvent.keyEvent(
        with: .keyDown, location: event.locationInWindow, modifierFlags: [],
        timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
        characters: "\r", charactersIgnoringModifiers: "\r",
        isARepeat: event.isARepeat, keyCode: event.keyCode) {
        let handled = sendKey(plain, action: GHOSTTY_ACTION_PRESS, surface: s)
        if !handled {                                    // fallback: inject CR directly
            var cr: UInt8 = 0x0D
            withUnsafePointer(to: &cr) { p in
                p.withMemoryRebound(to: CChar.self, capacity: 1) {
                    ghostty_surface_text_input(s, $0, 1)
                }
            }
        }
    }
    return
}
```

Why this and not the modifier guard `== .command`: numpad Enter (keyCode 76) also sets
`.numericPad`, so an equality check would miss it — use the explicit contains/absent checks the
codebase already uses (cf. the ⌘V block at `:935-937`).

## Alternative — ghostty config keybind (Approach A, simpler but incomplete)

Glint loads ghostty config overrides via `ghostty_config_load_string`
(`GhosttyManager.swift:144`), so one could add a keybind like `cmd+enter=text:\r` there. The
existing `hasBindingMod → sendKey → ghostty` flow would then emit the CR — **no Swift key code at
all.** Downsides: (1) it does **not** fire `.glintPaneReturnPressed`, so the sidebar's optimistic
agent-status flip wouldn't trigger on ⌘+Enter (minor, self-corrects on the next agent hook);
(2) ghostty's `text:` escape syntax for a carriage return needs verification against the embedded
libghostty version. Recommend **B** for parity; A is the fallback if we want zero Swift changes.

## Edge cases (handled)

- **Only pure ⌘+Return** is intercepted. ⌘⇧↩ / ⌥↩ / ⌃↩ are left alone — agents use Shift/Opt+Enter
  for a literal newline; those must keep working.
- **IME composition:** `!hasMarkedText()` guard — don't submit mid-composition (mirrors the
  existing `isShiftReturn` guard at `:976`).
- **Overrides any ghostty `cmd+enter` binding** (e.g. fullscreen). Intended; fullscreen stays
  available via the green button / `⌃⌘F`.
- **Generic:** works for any source of ⌘↩ — the BTT two-finger gesture *or* a manual ⌘+Return.
- Scoped to the focused pane; other panes unaffected.

## Optional polish (not required)

Gate it behind a Settings toggle ("Treat ⌘+Return as Return", default on) using the `glassEffect`
UserDefaults idiom, in case a future user binds ⌘+Enter to something else. Recommend shipping it
hardcoded-on first; add the toggle only if needed.

## Effort
~15 lines in `GhosttySurfaceView.keyDown`. No new entitlement, no config plumbing (Approach B).
Rebuild via `tmp/cursor-button/build-and-install.sh`.
