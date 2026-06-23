# Proposal: Orchestrator Self-Spawning of Worker Agents Through Glint

> **Status:** Draft for owner review
> **Author:** investigation synthesis, 2026-06-22
> **Scope:** READ-ONLY investigation. No code changed. All file:line citations verified against the working tree.

---

## 1. Verdict

**Feasible with a small, well-shaped addition — not a real build, and not free today.** Every *capability* the orchestrator needs already exists inside Glint as a public `@MainActor` method on `WorkspaceStore`: create a workspace (`addWorkspace()`, `WorkspaceStore.swift:1754`), mint a pane surface at a given cwd with a command pre-injected (`surfaceView(workspaceID:paneID:cwd:)`, `WorkspaceStore.swift:936`, feeding `initialInput` → ghostty `cfg.initial_input`, `GhosttySurfaceView.swift:115`/`303`). What does **not** exist is any way for code *outside the app process* — and a `claude` agent running in a pane is exactly that, a child process — to call those methods. There is no URL scheme (`Info.plist` has no `CFBundleURLTypes`), no CLI arg parsing, no XPC, and the one IPC surface that exists (`AgentBridge`, `~/.glint/run/agent.sock`) is **inbound-only**: agents report status *to* Glint, Glint never takes commands *from* them (`AgentBridge.swift:11-14`, accept loop at `:106-117`). The entire missing piece is a **thin inbound control channel** that routes a `spawn_worker` request onto the main actor and calls the three methods that already work. Smallest viable version: ~150–250 lines of Swift plus a ~30-line Bash helper. The forking/handover mechanics (`claude --resume … --fork-session`, prompt injection) are already proven by the auto-resume feature.

---

## 2. What Glint already gives us

| Capability | Symbol / surface | Location | Parameterizable? |
|---|---|---|---|
| Create workspace | `func addWorkspace()` | `WorkspaceStore.swift:1754` | **No** — takes zero args, name hardcoded `"New workspace"`, color cycles a palette. No cwd/command arg. |
| Workspace factory | `static func fresh(name:accentHex:symbol:)` | `WorkspaceStore.swift:286` | Yes for name/color; **workspace has no directory field** — cwd lives only on the `Pane`. |
| Pane / cwd model | `struct Pane { var workingDirectory: String?; var lastAgent: String? }` | `WorkspaceStore.swift:69-100` | cwd is per-pane, captured ~1s after spawn from the live shell via OSC 7. |
| Mint pane surface | `func surfaceView(workspaceID:paneID:cwd:)` | `WorkspaceStore.swift:936` | cwd is a param; **`initialInput` is computed internally** (line 960-968) — not yet a caller arg. |
| Inject a command at spawn | `initialInput` → `cfg.initial_input` | `GhosttySurfaceView.swift:109`, `:303` | **Yes — this is the load-bearing primitive.** Ghostty feeds the string to the PTY *after* the shell prompt is ready; "no timing dance" (comment `:956-959`). Today used only for `"claude --continue\n"` etc. |
| In-process store handle | `static private(set) weak var current: WorkspaceStore?` | `WorkspaceStore.swift:786` (set in `init`) | Usable only from code **inside** the Glint process — not from a pane subprocess. |
| Inbound agent IPC | `AgentBridge` Unix socket `~/.glint/run/agent.sock` | `AgentBridge.swift:11-14`, `:48-125` | **Read-only.** Parses `{"pane":…,"hook":…}` lines, posts `.glintAgentEvent`. No reply channel, no command parsing. |

**The proof that the model fits.** The auto-resume feature already does *exactly* the shape of thing we want — it picks a workspace's pane, decides on a command string, and hands it to the new surface as `initialInput`:

```swift
// WorkspaceStore.swift:960-977
let restoreCommand: String? = {
    switch pane.lastAgent {
    case "claude" where restoreClaudeSession: return "claude --continue\n"
    ...
}()
let v = GhosttySurfaceView(frame: .zero, initialCwd: cwd, …, initialInput: restoreCommand)
```

If `initialInput` can boot `claude --continue`, it can equally boot `cd <worktree> && claude --resume <main> --fork-session -n <slug>`. The creation-time injection path is finished work; only the *external trigger* is missing.

**Control surfaces that do NOT exist** (confirmed): URL scheme, CLI, XPC, AppleScript/`.sdef`, HTTP server, and — critically — any post-launch text injection (`pasteClipboardText`/`injectFileURLs` are `private`, `GhosttySurfaceView.swift:1589`/`1413`). One pane cannot send keystrokes to a sibling pane.

---

## 3. The mechanism

The orchestrator is a `claude` session in a Glint pane. From its own Bash it can: touch the filesystem freely, read its own env (`$GLINT_PANE_ID`, `$GLINT_AGENT_SOCK` are injected, `GhosttySurfaceView.swift:307-312`), and talk to a socket. It **cannot** reach into Glint's address space. So we add the **smallest inbound control channel** and route it straight into the three existing methods.

### Recommended: a `spawn_worker` command on a control socket (mirror of `AgentBridge`, but acting)

Add a `ControlBridge` modeled byte-for-byte on `AgentBridge`'s bind/listen/accept (`AgentBridge.swift:48-125`), listening on `~/.glint/run/control.sock` (0600, inside the existing 0700 `~/.glint/run` dir — same hardening rationale as the agent socket, `AgentBridge.swift:34-47`). On each accepted connection it parses one JSON request, hops to the main actor, and calls into `WorkspaceStore.current`:

```jsonc
// request the orchestrator sends
{ "op": "spawn_worker",
  "name": "pai-next-w1-<slug>",
  "cwd":  "/abs/path/to/worktree",
  "input": "claude --resume 'pai-next-orchestrator-main' --fork-session -n 'pai-next-w1-<slug>'\n" }
// reply
{ "ok": true, "workspace_id": "<uuid>", "pane_id": 0 }
```

Glint-side handler (new code, but every line below already has a working counterpart):

```swift
// new: WorkspaceStore.addWorkspace(name:cwd:initialInput:) -> (UUID, PaneID)
//   = Workspace.fresh(name:…) + set firstPane.workingDirectory = cwd
//     + remember initialInput for the first surfaceView() mint
let (wsID, paneID) = store.addWorkspace(name: req.name, cwd: req.cwd, initialInput: req.input)
store.selectedWorkspaceID = wsID   // bring it forward so the human sees it
```

The one real change to existing code: `surfaceView(...)` currently *computes* `initialInput` internally (`:960-977`). We let an explicitly-requested first-mint command take precedence over the auto-resume command. Roughly: store a pending `firstInput: String?` on the workspace (or a `[WorkspacePaneKey: String]` side-table on the store) and prefer it at `:977`. ~10 lines.

**Why a socket and not a URL scheme.** A URL scheme (`glint://spawn?…`) is the lighter macOS-native alternative and avoids writing an accept loop, but the handover prompt is multi-line free text — URL-encoding a TASK.md body is fragile and size-limited. The socket is *isomorphic to the surface Glint already ships* (`AgentBridge`), reuses its security model verbatim, gives a structured reply (the worker's workspace UUID, which the orchestrator wants for tracking), and carries arbitrary payloads. It fits Glint's existing "agents talk to the app over `~/.glint/run/*.sock`" design rather than bolting on a second paradigm.

### The handover prompt — two options, pick one

The forked `claude` needs its task. Forked CLI sessions do **not** auto-receive a prompt; the orchestrator must deliver it. Two grounded paths:

- **(A) Drop a file, point the worker at it (recommended — robust, no escaping hell).** Orchestrator writes `TASK.md` into the worktree *before* spawning. The `input` command tells the worker to read it: `… --fork-session -n <slug> "Read ./TASK.md and begin."` — or simply rely on the worker's own bootstrap convention. Multi-line content lives in a file, never in the injected command string, so no shell/JSON quoting risk.
- **(B) Inline the prompt in `initialInput`.** Append the prompt as a trailing `claude` positional arg in the same injected string. Works, but every newline/quote in the prompt must survive Bash → JSON → ghostty PTY. Use only for short one-liners.

> **Uncertainty flagged:** investigators confirmed `--fork-session` / `-n` are passed through as an opaque shell string (Glint never parses agent flags), but **no investigator ran `claude --resume … --fork-session` to confirm the exact flag spelling or that a forked session accepts a trailing prompt positional**. Validate the literal `claude` invocation in a real pane before wiring it into the skill (step 0 below).

---

## 4. The end-to-end self-spawn flow

Orchestrator pane (`claude`), via a dispatch skill that shells out:

```bash
# worker-spawn.sh  <slug>  <branch>  <task-file>
set -euo pipefail
SLUG="$1"; BRANCH="$2"; TASK_SRC="$3"
REPO="$(git rev-parse --show-toplevel)"
WT="$REPO/../worktrees/pai-next-w1-$SLUG"

# (1) create the worktree
git worktree add -b "$BRANCH" "$WT" HEAD

# (1b) copy the task + the permission settings into the worktree
#      (forked sessions do NOT inherit the orchestrator's allowlist — see Guardrails)
cp "$TASK_SRC" "$WT/TASK.md"
mkdir -p "$WT/.claude"
cp "$REPO/.claude/settings.json" "$WT/.claude/settings.json"   # scoped worker perms

# (2)+(3) ask Glint to create a workspace at the worktree and boot a forked worker
INPUT="cd '$WT' && claude --resume 'pai-next-orchestrator-main' --fork-session -n 'pai-next-w1-$SLUG' \"Read ./TASK.md and begin.\"\n"
REQ=$(jq -nc --arg n "pai-next-w1-$SLUG" --arg cwd "$WT" --arg in "$INPUT" \
        '{op:"spawn_worker", name:$n, cwd:$cwd, input:$in}')

# send to the new control socket; read back the workspace id
printf '%s' "$REQ" | nc -U "$HOME/.glint/run/control.sock"
```

Sequence:

1. **Worktree** — `git worktree add` creates an isolated checkout on a fresh branch. (Pure filesystem; works today.)
2. **Handover + perms staged** — `TASK.md` and a scoped `.claude/settings.json` are placed in the worktree *before* the worker boots.
3. **Drive Glint** — one JSON line over `~/.glint/run/control.sock` → `ControlBridge` → main actor → `addWorkspace(name:cwd:initialInput:)` → workspace appears in the sidebar, pane mints at the worktree, ghostty injects the `cd … && claude --resume … --fork-session …` string after the shell is ready.
4. **Worker runs** — the forked `claude` reads `TASK.md`, starts working, and (because the pane gets `$GLINT_AGENT_SOCK`/`$GLINT_AGENT_EVENTS` injected, `GhosttySurfaceView.swift:307-312`) reports thinking/tool/needs-permission status back through the *existing* `AgentBridge` path — so the sidebar reflects the worker live with zero extra work.
5. **Human watches/manages** — the orchestrator's job ends at handoff; the person supervises the worker pane.

---

## 5. Guardrails

Self-spawning is a privilege-amplification surface: a looping orchestrator could fork workers without bound, and the socket is reachable by any process running as the user. Bake these into the **first** slice, not a follow-up.

- **Human-in-the-loop before spawn (default ON).** Mirror the `restoreClaudeSession` design philosophy — its doc note explicitly says "auto-running a network-hitting CLI on launch without confirmation is sensitive" and the toggle **defaults OFF** (`WorkspaceStore.swift:529`, resume analysis report). Apply the same bar: `ControlBridge` surfaces a native confirmation ("Spawn worker *pai-next-w1-slug* at *<worktree>*? [Approve]") and only calls `addWorkspace` on approval. An "auto-approve spawns" toggle exists but defaults OFF.
- **Max-concurrent workers.** `ControlBridge` rejects `spawn_worker` when live worker count ≥ N (e.g. 3), returning `{"ok":false,"error":"max_workers"}`. Count = workspaces whose name matches `pai-next-w*` with an active surface. This is the hard stop against an orchestrator loop — enforce it in Swift, not in the prompt (per repo principle: unbounded-harm constraints go in code, not instructions).
- **Scope-bounded worker contract.** `TASK.md` is the contract: one branch, one bounded deliverable, "do not spawn further workers." A worker must not itself reach the control socket — either don't inject `$GLINT_CONTROL_SOCK` into worker panes, or have `ControlBridge` reject requests originating from a pane already tagged as a worker (tag via an env var set at spawn).
- **Permissions do not inherit — copy settings into the worktree.** A forked `claude` session in a new cwd gets that worktree's `.claude/settings.json`, **not** the orchestrator's in-memory allowlist. Stage a *scoped* settings file (step 1b above) — deliberately narrower than the orchestrator's (e.g. no destructive Bash, repo-local paths only). > **Uncertainty:** the exact precedence/merge of forked-session permissions was not verified by any investigator; confirm in step 0.
- **Kill / cleanup a runaway.** Two levers, both existing: (a) the human closes the pane/workspace in the UI (standard Glint affordance) — but note **no investigator confirmed that closing a pane sends SIGTERM to the `claude` child**; verify, and if not, add an explicit `kill_worker` op to `ControlBridge` that terminates the pane's process group. (b) Cleanup the worktree: `git worktree remove --force "$WT" && git branch -D "$BRANCH"`. A `glint worker reap` helper should do both.
- **Socket trust boundary.** `control.sock` inherits `AgentBridge`'s 0600-in-0700-dir hardening (`AgentBridge.swift:34-47`, `:104`), so only the same user reaches it. That's the existing bar; it means any code you run can spawn workers — acceptable given Glint already runs sandbox-off, but it's why the human-approval gate is non-negotiable.

---

## 6. Implementation plan

### First viable slice — spawn ONE worker, end-to-end

**Step 0 — De-risk the agent invocation (no code).** In a real Glint pane, manually run `cd <worktree> && claude --resume '<main>' --fork-session -n '<slug>' "Read ./TASK.md and begin."`. Confirm: the flag spelling, that the fork starts, that it consumes a trailing prompt or reads `TASK.md`, and how the forked session resolves `.claude/settings.json`. This validates the three flagged uncertainties before any Swift is written.

**Glint-side (Swift):**
1. **`WorkspaceStore.addWorkspace(name:cwd:initialInput:) -> (UUID, PaneID)`** — wraps `Workspace.fresh` (`:286`), sets the first pane's `workingDirectory = cwd`, stashes `initialInput` for the first mint, appends, sets `selectedWorkspaceID`. ~25 lines, beside `:1754`.
2. **Prefer requested `initialInput` in `surfaceView`** — at `:977`, use the stashed first-mint command when present, else fall back to the existing auto-resume `restoreCommand`. ~10 lines.
3. **`ControlBridge.swift`** — copy `AgentBridge` bind/listen/accept (`:48-125`), path `~/.glint/run/control.sock`, parse one `{op,name,cwd,input}` JSON, **show the approval prompt**, enforce `maxWorkers`, then `DispatchQueue.main.async { WorkspaceStore.current?.addWorkspace(name:cwd:initialInput:) }`, reply `{ok,workspace_id,pane_id}`. Start it next to `AgentBridge.shared.start()`. ~120 lines.

**Orchestrator-side (skill/CLI):**
4. **`worker-spawn.sh`** (§4) — worktree + stage `TASK.md` + scoped `.claude/settings.json` + one `nc -U` to the socket.
5. **A `spawn-worker` dispatch skill** that gathers `{slug, branch, task}`, writes `TASK.md`, calls the script, and reports the returned workspace UUID.

**Verify the slice:** orchestrator pane runs the skill → approval prompt appears → approve → new workspace at the worktree → forked `claude` reads `TASK.md` and starts → sidebar shows its live status via the existing `AgentBridge` path.

### Generalize to N (after the single worker is proven)
6. Enforce `maxWorkers` ceiling and the worker-can't-spawn rule.
7. Add `kill_worker` + a `glint worker reap` cleanup helper (pane process-group kill + `git worktree remove`).
8. Optional later: a small `glint` CLI wrapping the socket (`glint spawn --cwd … --input …`) so the orchestrator calls a binary instead of hand-rolling `nc`/`jq` — nicer ergonomics, not required for function.

---

### Honest uncertainties (carry into step 0)
1. Exact `claude --resume … --fork-session -n …` flag spelling and whether it takes a trailing prompt positional — **not executed by any investigator.**
2. Forked-session permission precedence vs. the worktree's `.claude/settings.json` — **inferred, not confirmed.**
3. Whether closing a Glint pane terminates the `claude` child process — **not confirmed**; may require an explicit `kill_worker` op.

Relevant files for implementation: `/Users/zhar2/Documents/Github/glint/Glint/Workspace/WorkspaceStore.swift` (`:286`, `:936`, `:1754`), `/Users/zhar2/Documents/Github/glint/Glint/Agent/AgentBridge.swift` (`:48-125`, the template for `ControlBridge`), `/Users/zhar2/Documents/Github/glint/Glint/Pane/GhosttySurfaceView.swift` (`:103-124`, `:303`), and a new `/Users/zhar2/Documents/Github/glint/Glint/Agent/ControlBridge.swift`.