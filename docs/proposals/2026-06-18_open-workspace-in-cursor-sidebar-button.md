# Proposal — "Open workspace in Cursor" sidebar button

**Author:** Ruijian · **Date:** 2026-06-18 · **Repo:** `Ruijian-Zha/glint` (fork)
**Status:** proposal + research complete (code-verified). Pending: pick a UX variation → implement → rebuild.

## TL;DR

Add a small clickable **editor icon** to each workspace card in the left sidebar. Click → open that
workspace's current folder in **Cursor**. If Cursor already has that folder open → **focus** the
existing window; else open a new one.

- **Mechanism:** `NSWorkspace.shared.open([folderURL], withApplicationAt: cursorAppURL, configuration:)`
  — the *same* native API Glint already uses (`GhosttyManager.swift:253`). The focus-if-open behavior
  comes **for free** from Cursor/VS Code's "one window per folder" rule. **No new entitlement, no TCC
  prompt, no subprocess.**
- **The folder to open** is already tracked: the focused pane's live `workingDirectory`
  (`WorkspaceStore.swift:996-998`, polled ~1s).
- **3 small code additions:** a `Workspace.resolvedCwd` accessor, a `WorkspaceStore.openInEditor(_:)`
  method, and a button in `WorkspaceCard`.
- **Pick one of 4 UX variations** (below). Recommended: **A — hover-reveal trailing icon**, shipped
  together with **C — context-menu item** (for keyboard/VoiceOver discoverability).

> ⚠️ **Build blocker (verified on this machine 2026-06-18):** only **Command Line Tools** are
> installed, not full **Xcode** (`xcodebuild` → "requires Xcode"). The code change is trivial, but you
> **cannot rebuild/reinstall** until you install **Xcode 26.x** (CI uses `macos-26`). See §6.

---

## 1. Goal & behavior

| Want | Detail |
|---|---|
| A per-card affordance | A Cursor/editor icon on each workspace card in `SidebarView` |
| Click → open in Cursor | Open the card's folder (its focused pane's cwd) in Cursor.app |
| Focus-if-open | Folder already open in Cursor → focus that window; else new window |
| Don't break card-select | Clicking the icon must NOT also select/switch the workspace |
| Graceful when N/A | No cwd yet, remote/ssh cwd, or Cursor not installed → no-op / fallback |

---

## 2. Grounded facts (code-verified)

- **Injection point:** `Glint/Chrome/SidebarView.swift` → `private struct WorkspaceCard`, body's outer
  `HStack` (`:595-629`): `workspaceIcon (28×28)` · `VStack(name + secondaryRow)` · `Spacer`. The card
  already has `@State isHovered` (`:584`, set by `.onHover` `:655`), a `.contextMenu` (`:681-698`), and
  an `.onTapGesture { store.selectWorkspace }` (`:674`).
- **The path:** resolved exactly like `Workspace.displayName` (`WorkspaceStore.swift:312-316`) — the
  focused pane's `workingDirectory`, else any pane's. It's an **absolute** path (ghostty OSC-7 writes
  absolute), polled live (`:996-998`). `nil` for a brand-new pane until the first poll.
- **Opening externally is an existing pattern:** `NSWorkspace.shared.open(url)` at
  `GhosttyManager.swift:253`; `activateFileViewerSelecting` / `open(url)` at
  `GhosttySurfaceView.swift:1414-1416`. We are **not** introducing a new capability class.
- **Entitlements:** sandbox is **off** (`Glint/Resources/Glint.entitlements`, `app-sandbox=false`).
  Launching another app via `NSWorkspace` needs **no** Automation/AppleEvents entitlement.
- **⚠️ Naming trap:** the "Cursor" card in `SettingsView.swift:564` is the **terminal text caret**
  (block/bar/underline) — unrelated to the Cursor **editor**. Keep them distinct in UI copy.
- **Cursor on this Mac:** installed, bundle id **`com.todesktop.230313mzl4w4u92`** (ToDesktop/Electron
  packaging — *not* `com.microsoft.VSCode`), verified via `osascript -e 'id of app "Cursor"'`.

---

## 3. Mechanism — why `NSWorkspace.open(folder, withApp:)`

The folder is delivered to Cursor as an **open-document Apple event**; VS Code-family editors enforce
**one window per folder** and focus the existing window instead of duplicating (confirmed:
`microsoft/vscode#35207`). So passing the *folder* (not CLI flags) gives focus-if-open natively.

Alternatives considered and rejected:

| Approach | Why not |
|---|---|
| `cursor` CLI via `Process` | Introduces Glint's **first subprocess** (new surface); shim not guaranteed on PATH. Works, but strictly more moving parts than NSWorkspace. |
| `/usr/bin/open -b <id> <folder>` via `Process` | Same LaunchServices call as NSWorkspace but out-of-process; no typed error handler. Strictly worse. |
| `NSAppleScript` "tell app Cursor…" | **Triggers the Automation TCC prompt** + needs `NSAppleEventsUsageDescription`; fragile. Explicitly avoid. |

**Caveats handled in code:**
1. **Remote/ssh or nonexistent cwd** → guard with `path.hasPrefix("/")` + `FileManager.fileExists(isDirectory:)`; no-op (beep) otherwise. (True remote editing = Cursor Remote-SSH, out of scope.)
2. **`nil` cwd** (fresh pane) → hide/disable the icon.
3. **Cursor not installed** → resolve by bundle id with fallback chain `Cursor → VS Code → VSCodeInsiders`, final fallback `activateFileViewerSelecting` (reveal in Finder — existing Glint pattern).
4. Don't set `OpenConfiguration.arguments` (unreliable for a running Electron app) — pass the folder URL.

---

## 4. Implementation plan

### 4.1 `Workspace.resolvedCwd` — new accessor (`WorkspaceStore.swift`, after `displayName` ~:317)

```swift
/// The absolute on-disk path this workspace currently points at: the focused
/// pane's live working directory (polled ~1s, :996-998), falling back to any
/// pane that has one. Same resolution as `displayName` (:314-315) but returns
/// the raw absolute path, not the short label. nil until ghostty reports a cwd.
var resolvedCwd: String? {
    let cwd = (selectedTab?.focusedPane).flatMap { panes[$0]?.workingDirectory }
        ?? panes.values.compactMap(\.workingDirectory).first
    guard let cwd, !cwd.isEmpty else { return nil }
    return cwd
}
```
Computed (not stored) so it stays live with the 1s poll's `@Published workspaces` republish.

### 4.2 `WorkspaceStore.openInEditor(_:)` — new method (near `selectWorkspace` ~:1414)

```swift
/// Open a workspace's current folder in Cursor, focusing the existing window
/// if that folder is already open (Cursor's one-window-per-folder behavior),
/// else opening a new one. Falls back to VS Code, then Finder.
func openInEditor(_ ws: Workspace) {
    guard let path = ws.resolvedCwd, path.hasPrefix("/") else { NSSound.beep(); return }
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
        NSSound.beep(); return                      // remote/ssh/nonexistent → no phantom window
    }
    let folder = URL(fileURLWithPath: path, isDirectory: true)
    let bundleIDs = ["com.todesktop.230313mzl4w4u92",   // Cursor (verified)
                     "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]
    let ws_ = NSWorkspace.shared
    guard let appURL = bundleIDs.lazy
            .compactMap({ ws_.urlForApplication(withBundleIdentifier: $0) }).first else {
        ws_.activateFileViewerSelecting([folder]); return       // no editor → Finder
    }
    let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true
    ws_.open([folder], withApplicationAt: appURL, configuration: cfg) { _, err in
        if err != nil { DispatchQueue.main.async { ws_.activateFileViewerSelecting([folder]) } }
    }
}
```

### 4.3 The button in `WorkspaceCard` — depends on the chosen variation (§5)

Recommended (variation A) helper, defined near `workspaceIcon` (~:744), wired into the outer `HStack`
right before `Spacer(minLength: 0)` (`:628`):

```swift
@ViewBuilder
private func openInEditorButton() -> some View {
    if ws.resolvedCwd != nil {
        Button { store.openInEditor(ws) } label: {
            Image(systemName: "arrow.up.forward.app")        // or "chevron.left.forwardslash.chevron.right"
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text2)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())                   // whole 20×20 tappable
        }
        .buttonStyle(.plain)                                  // Button tap wins over card .onTapGesture
        .help("Open in Cursor")
        .opacity(isHovered ? 1 : 0)                           // reveal on hover; slot stays allocated
        .allowsHitTesting(isHovered)
        .animation(.easeOut(duration: 0.16), value: isHovered)
    }
}
```

**Tap-conflict resolution (key):** a real SwiftUI `Button` consumes its own click; it does **not**
propagate to the card's ancestor `.onTapGesture` (`:674`) — so the icon opens the editor *without*
selecting the workspace. Requirements: it's a `Button` (not a bare `Image`), `.buttonStyle(.plain)`,
and `.contentShape(Rectangle())` on the label. The reorder `DragGesture` (`minimumDistance:6`, `:719`)
is unaffected (a click < 6pt never starts it).

**Hover-reveal:** reuse the existing `isHovered`. Drive with `.opacity` (not `if isHovered`) so the
20pt slot is always allocated and revealing it never reflows the name/secondary VStack.

---

## 5. UX variations — **pick one**

Run the visual picker: `glint/tmp/cursor-button/preview.html` (side-by-side mockups) and record your
choice with `glint/tmp/cursor-button/pick.sh`. Summary:

| Pick | Variation | Placement | Interaction | Best for | Tradeoff |
|---|---|---|---|---|---|
| **A** ✅ rec | Hover-reveal trailing icon | Right edge of card (the empty Spacer area) | Fades in on hover; click opens | Calm sidebar, zero rest-noise | Invisible until hover (pair with C) |
| **B** | Always-on subtle icon | Same right-edge slot | Always shown dim → brightens on hover | Max discoverability | Permanent visual weight on every card |
| **C** | Context-menu + ⌘ shortcut | No card glyph; right-click menu | Right-click → "Open in Cursor"; ⌘⏎ | Keyboard/VoiceOver, zero pixels | Low discoverability |
| **D** | Icon on the cwd/metadata row | Lower "2 tabs · 3 panes" line | Hover/always small glyph | Semantically near the path | Row swaps to status when running → fiddly |

**Recommendation: A + C together.** A gives a clean visible affordance; C makes it keyboard- and
VoiceOver-accessible (the hover icon is `accessibilityHidden` since the card is a combined a11y
element). B is the fallback if you want it always visible. D is the most edge-case-prone (the metadata
row is replaced by a status line while an agent runs).

### Icon sub-choice
- **`chevron.left.forwardslash.chevron.right`** (`</>`) — literally "code editor". (macOS 11+.)
- **`arrow.up.forward.app`** — "open in external app". (macOS 11+.)
Both render in the existing `Image(systemName:)` idiom. Pick in the same picker.

---

## 6. Build & reinstall from source

> **Blocker:** install **full Xcode 26.x** first — this machine has only Command Line Tools
> (`xcode-select -p` → `/Library/Developer/CommandLineTools`; `xcodebuild` → "requires Xcode").

```bash
# 0. one-time: point the toolchain at full Xcode
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
xcodebuild -version            # expect Xcode 26.x

cd /Users/zhar2/Documents/Github/glint
# 1. init the ghostty submodule (currently EMPTY — build hard-fails otherwise)
git submodule update --init --recursive
# 2. fetch the prebuilt, checksum-pinned GhosttyKit.xcframework (public, no secrets)
bash scripts/setup-ghosttykit.sh
# 3. regenerate the Xcode project (xcodegen drives it from project.yml; required after editing project.yml)
brew install xcodegen && xcodegen generate
# 4. build a DEV bundle (Debug → bundle id app.glint.Glint.dev → isolated, no Sparkle clobber)
xcodebuild -project Glint.xcodeproj -scheme Glint -configuration Debug \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
```

For a **Release** install over the current app, mirror `release.yml` (archive → export →
`codesign --force --deep --sign -` → copy to `/Applications` → `xattr -dr com.apple.quarantine`).

**Two gotchas that will bite:**
1. **Sparkle auto-update will clobber a Release local build within ~1h** (`SUEnableAutomaticChecks=true`,
   hourly, feed = chenbstack/glint). **Use Debug** (`app.glint.Glint.dev`, separate feed/state) for
   iteration — or set `SUEnableAutomaticChecks=false` / bump the version before building Release.
2. **Bundle-id collision** with the brew copy (`app.glint.Glint`). For Release, remove the brew copy
   first (`brew uninstall --cask glint`); Debug avoids this entirely via the `.dev` id.

GhosttyKit fetch is **unauthenticated and checksum-pinned** (current submodule SHA `0f86761` is in
`scripts/ghosttykit-checksums.txt`), so it works for a local dev. `Vendor/`, `build/`, `dist/` are
gitignored — they won't pollute the feature diff.

---

## 7. Testing

1. Hover a card → icon appears (variation A) → click → Cursor opens that folder.
2. With the folder **already open** in Cursor → click → the existing window **focuses** (no duplicate).
3. Click the icon → workspace is **not** selected/switched (tap-conflict check).
4. Fresh pane (no cwd yet) → icon hidden/disabled.
5. An ssh/remote or nonexistent path → no-op (beep), **no phantom Cursor window**.
6. Quit Cursor, rename it / test fallback → VS Code or Finder reveal.

---

## 8. Open questions
- **Variation A vs A+C vs B** — your pick (the picker records it).
- **Icon:** `</>` vs `arrow.up.forward.app`.
- **Scope to Cursor only**, or generic "open in editor" honoring a configurable editor (a Settings row)?
  Recommend: ship Cursor-first with the VS Code fallback now; add a Settings editor-picker later if wanted.
