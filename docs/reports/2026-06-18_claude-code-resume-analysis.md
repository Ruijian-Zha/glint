# Analysis report — "Claude Code sessions don't resume in Glint"

**Author:** Ruijian · **Date:** 2026-06-18 · **Repo:** `Ruijian-Zha/glint` (fork)
**Reported symptom:** after chatting with **Claude Code** in Glint, exiting, and restarting,
the previous conversation/context is gone — "as if chat history isn't saved to the local
cache." Reported as fatal (makes Claude Code unusable in Glint).

## TL;DR — the premise is wrong, and the real cause is a one-toggle setting

**Session persistence is NOT broken.** Hard evidence below proves Claude Code saves and resumes
correctly on this machine, including inside Glint workspace dirs. The actual cause of "doesn't
return to the previous context on restart" is that **Glint's auto-resume feature
(`restoreClaudeSession`) is OFF by default** — so on app/pane restart Glint boots a *fresh shell*
instead of re-running `claude --continue`. **Fix: turn it on** (Settings → Agents → "Restore
Claude session"), or flip its default to `true` in code (1 char). Persistence, cwd, hooks, and
`~/.claude` are all healthy.

---

## Evidence (what I measured)

### 1. Persistence works — definitively
- `~/.claude/projects/-Users-zhar2-Documents-Github-pai-next/8d8cfd04-…jsonl`: recorded
  **`cwd:/Users/zhar2/Documents/Github/pai-next`**, `gitBranch:main`, **87,956 lines**, first
  message `2026-05-05`, **last appended today 14:10**. A single session resumed and appended for
  **6 weeks** → resume works. pai-next has **5** session files total.
- Buckets exist for every real project (work-os, life-os, pai-next, pai, …) with sessions.

### 2. The cwd Glint launches in is CORRECT (live `lsof -d cwd` on the running app)
| Glint pane shell | cwd |
|---|---|
| pai-next | `/Users/zhar2/Documents/Github/pai-next` ✓ |
| life_os | `/Users/zhar2/Documents/Github/life_os` ✓ |
| work_os | `/Users/zhar2/Documents/Github/work_os` ✓ |

Claude Code keys sessions by cwd (`~/.claude/projects/<cwd-slugified>/`). The cwds match the
projects, so sessions land in the right bucket and `--resume` (run in the same pane/cwd) reads it.
`GhosttySurfaceView` sets `cfg.working_directory = initialCwd` (`:285-287`); `initialCwd` is the
pane's stored cwd (`WorkspaceStore.swift:972`). No drift.

### 3. Nothing in Glint redirects or disables session storage
- **HOME / config dir:** not overridden. The surface only injects `GLINT_PANE_ID` +
  `GLINT_AGENT_SOCK` env (`GhosttySurfaceView.swift:303-305`). No `CLAUDE_CONFIG_DIR` in the rc.
- **Hooks (`AgentHookInstaller`)** only merge status-reporter entries into
  `~/.claude/settings.json` pointing at `~/.glint/hooks/glint-report.sh`, which drains stdin and
  pings a local socket (`{pane,hook,agent}`). It never touches session storage. settings.json is
  clean (`cleanupPeriodDays` unset → default 30d; no session-disabling keys).

→ The three "obvious" causes (wrong cwd / moved `~/.claude` / hook interference) are **ruled out.**

---

## Root cause — Glint's auto-resume is off by default

Glint *has* an auto-resume feature, but it's gated and defaults off:

```swift
// WorkspaceStore.swift:529  — defaults to FALSE
@Published var restoreClaudeSession: Bool =
    (UserDefaults.standard.object(forKey: "glint.restoreClaudeSession") as? Bool) ?? false

// WorkspaceStore.swift:960-968 — only injects `claude --continue` on pane boot when
// the toggle is ON *and* the pane's last agent was claude
let restoreCommand: String? = {
    guard let pane = …panes[paneID] else { return nil }
    switch pane.lastAgent {
    case "claude" where restoreClaudeSession: return "claude --continue\n"
    …
    }
}()
// …passed as initialInput to the new surface (:976)
```

So on Glint restart, a pane with `restoreClaudeSession == false` comes back as a **plain shell**
— no `claude --continue`, no context. That is exactly "doesn't return to the previous context."
The comment at `:524-526` explains the deliberate default: auto-running a network-hitting CLI on
launch without confirmation is sensitive, so it ships off.

The rest of the chain is sound:
- `pane.lastAgent` is set to `"claude"` via the agent hooks → socket → `WorkspaceStore.swift:1042`.
- The toggle is exposed in the UI: `SettingsView.swift:684` (`Toggle(isOn: $store.restoreClaudeSession)`).
- When ON, `claude --continue` resumes the **most recent** session for that cwd — which works
  (proven by the pai-next session above).

## Why "manual `--resume` also fails" is most likely a cwd/dir mismatch

The evidence says manual `--resume` works (pai-next resumes fine; cwd is correct). If it appears
to fail, the likely reasons:
- **Different directory.** There is **no** `~/.claude/projects/-Users-zhar2-Documents-Github-glint`
  bucket — i.e., Claude Code has never been run *as the CLI* in the glint fork dir. Running
  `--resume` there would correctly show "no sessions." Sessions are per-cwd; a subdir or sibling
  dir is a different project.
- Testing `--resume` in a pane whose cwd differs from where the chat happened.

---

## Recommendations

1. **Immediate (no rebuild):** Settings → Agents → enable **"Restore Claude session"**. On next
   restart, claude panes auto-run `claude --continue` and come back with context.
2. **Make it the default (optional, 1-char):** `WorkspaceStore.swift:529` `?? false` → `?? true`.
   Trade-off: auto-runs `claude --continue` (a network CLI) on every claude pane at launch without
   a prompt — the reason it ships off. Acceptable for a personal fork; document it.
3. **If auto-resume still doesn't fire after enabling:** the gap is `lastAgent` not being set to
   `"claude"` — verify the hooks are installed (Settings → Agents shows "Installed") and that the
   `SessionStart` hook reaches the socket. lastAgent is what `:964` switches on.
4. **30-second self-diagnostic** (run in a Glint pane to confirm persistence for any dir):
   ```bash
   pwd                                   # note the dir
   claude                                # chat one line, then exit
   ls -lt ~/.claude/projects/"$(pwd | sed 's#/#-#g; s#_#-#g')"/   # newest .jsonl = your session
   claude --resume                       # should list it
   ```
   If the `.jsonl` appears but `--resume` doesn't list it → real bug, capture and escalate.
   If no `.jsonl` appears → claude isn't persisting in that pane (then check `echo $HOME`, TTY).

## Bottom line
Not a data-loss bug. Sessions are saved and resumable. The fix is enabling (or defaulting on)
`restoreClaudeSession` so Glint auto-`--continue`s on restart, matching the behavior you get by
manually resuming in another terminal.
