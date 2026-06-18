# Deep analysis — Claude Code loses the LAST messages on `--resume` (Glint)

**Author:** Ruijian · **Date:** 2026-06-18 · **Repo:** `Ruijian-Zha/glint` (fork)
**Supersedes** the first-pass report (`2026-06-18_claude-code-resume-analysis.md`), which only found
the `restoreClaudeSession` toggle. The real defect is narrower and confirmed below.

**Repro (user):** type "hi" (interrupted turns) in Claude Code inside Glint → **Ctrl+C twice to
exit** → `claude --resume` → the last "hi" exchanges are **gone**. Only in Glint; the system
terminal keeps them.

## TL;DR

It's a **lost-tail-on-exit** problem, not data corruption and not the auto-resume toggle. Claude
Code writes the transcript append-only, one line per message, and commits the **last line(s) of a
turn in a brief post-turn flush window**. If the process dies inside that window, exactly the tail
is lost — a documented Claude Code race (upstream issues below). **Whether Glint *causes* it depends
on how you exit**, and the code evidence splits cleanly:

| Exit path | Glint behavior | Tail safe? |
|---|---|---|
| **Double-Ctrl+C self-exit, resume in same pane** | Glint forwards `^C` as a plain `0x03` byte — **byte-for-byte a stock terminal**, no kill code | = same as system terminal → if it's lost here, it's **Claude Code's own flush race** (also hits other terminals, intermittently) |
| **Close the pane / workspace** | stock ghostty **graceful `SIGHUP` to the process group + `waitpid` loop** | mostly safe |
| **⌘Q quit Glint** | `applicationWillTerminate` only saves the window frame — **no graceful surface teardown** → macOS reaps claude abruptly | ❌ **Glint-side gap — abrupt reap can truncate the flush** |

So: if your loss happens after **quitting/closing** Glint, it's a real Glint bug we can fix. If it
happens on **pure double-Ctrl+C in the same pane**, the code shows Glint isn't the killer — it's the
upstream Claude Code flush race. The diagnostic below tells you which.

## Evidence

### Claude Code's persistence model + the flush race (web)
- Sessions = append-only JSONL, one line per message, written as the session runs (databunny / claude-dev.tools).
- **The tail is committed in a post-turn/post-EOF flush window; killing the process before it
  completes drops exactly the last message** — `anthropics/claude-agent-sdk-python#625`:
  *"transport.close() sends SIGTERM too quickly, before the subprocess has time to flush the session
  file … It's a race condition."*
- Interrupted turns' closing record is the fragile, last-written piece —
  `anthropics/claude-code#18880`: *"Messages ARE written incrementally … but the final … record is
  never written when the session is killed."*
- Same symptom reported generally — `claude-code#26519` (*"JSONL exists but … never persisted"*),
  `#43303`/`#19434` (*"after exiting via ctrl+c … 50% of the time the chat doesn't appear"*). So this
  race exists outside Glint too; it's **intermittent and timing-dependent**.
- `SIGKILL` = no flush; graceful `SIGINT/SIGHUP` + wait = flush (SUSE). Abrupt PTY/child teardown
  drops buffered data specifically under SIGKILL (`nodejs/node#12101`, `microsoft/node-pty#726`).

### Glint code forensics (the decisive part)
- **No abrupt kill on self-exit.** `^C` → `GhosttySurfaceView.swift:1027-1033` → `sendKey` →
  `ghostty_surface_key` (text=nil). Grep for `SIGKILL/SIGTERM/SIGINT/kill(/Process.terminate/_exit`
  across `Glint/` → **nothing**. `closeSurface` callback is a no-op (`GhosttyManager.swift:274-278`).
  The 1s `foregroundProcessName()` poll is read-only.
- **The only kill is graceful + only on deinit:** ghostty fork `termio/Exec.zig:1136-1190` →
  `killpg(pgid, SIGHUP)` in a `waitpid(WNOHANG)+10ms` loop, fired from `Surface.deinit` (pane
  close / workspace delete). SIGHUP, not SIGKILL.
- **⌘Q gap:** `AppDelegate.swift:66-71` `applicationWillTerminate` only persists the window frame;
  `:42-48` returns `.terminateNow`. No surface teardown → macOS reaps children with no graceful
  SIGHUP+wait. **This is the one Glint path that can truncate an in-flight flush.**
- Shell launch is stock ghostty `/usr/bin/login -flp` (`Exec.zig:1512`) — identical to Ghostty.app.

### Session-file forensics
- Claude Code **does** persist interrupted turns when the process lives: `[Request interrupted by
  user]` markers — 260 in the pai-next session, 12 in this work_os session — all with timestamps+uuid.
- User messages flush at submit (the bug-report turn's user line landed ~73s before its reply).
- The whole bug-report conversation is fully persisted — only the **last-before-exit** tail goes
  missing. Files are append-only, no rewrite/truncation → the loss is a **missing final append**.
- **Correction to one forensic claim:** `bridge-session` / `bridgeSessionId: cse_…` / `last-prompt`
  / `mode` / `permission-mode` entries are **Claude Code's own** session-metadata + claude.ai
  cloud-bridge records — they appear in this **Cursor**-run session too, so they are **not** a
  Glint-specific extra writer. Glint is not injecting into the jsonl. (This rules out "Glint's bridge
  drops the tail.")

## Root cause

The tail is committed in Claude Code's post-turn flush window; losing it requires the writer to die
inside that window. **On the pure double-Ctrl+C-in-same-pane path, Glint is not the killer** (code
proof above) — so that loss is the upstream Claude Code race, which also bites other terminals
intermittently. **The Glint-specific amplifier is the ⌘Q quit path**, which reaps children without
a graceful teardown; if your repro includes quitting/closing Glint between exit and resume, that's
the Glint bug.

## Recommendations

1. **Disambiguate first (60s):** run the diagnostic below to learn which path you're on — it changes
   the fix.
2. **Glint fix (in our control) — graceful quit teardown.** In `AppDelegate.applicationShould
   Terminate`, before terminating, iterate `WorkspaceStore.current.surfaceViews` and free each
   surface (runs ghostty's `Surface.deinit → subprocess.stop()` graceful `SIGHUP`+`waitpid`), or
   return `.terminateLater` and tear down async with a short grace window. Today ⌘Q skips this.
   This guarantees claude gets time to flush its tail even on quit. (Pane-close is already graceful.)
3. **For the upstream race (pure self-exit):** can't be fully fixed in Glint — it's Claude Code's
   flush timing. Mitigations: exit claude with **`/quit`** (graceful) instead of double-Ctrl+C; or
   pause ~1s after the turn settles before the second Ctrl+C. File/track upstream
   `claude-agent-sdk#625` / `claude-code#18880` (fsync the tail on SIGINT).
4. **Belt-and-suspenders (optional):** Claude Code already records a recoverable signal; if desired,
   Glint could on resume reconcile a just-typed prompt it captured against the jsonl — but prefer
   the upstream fix over re-injecting.

## Diagnostic (run in a Glint pane; tells us which path)

```bash
B=~/.claude/projects/"$(pwd | sed 's#/#-#g; s#_#-#g')"
S=$(ls -t "$B"/*.jsonl | head -1)            # current session file
claude            # type "hi", Enter, Ctrl+C once (interrupt), Ctrl+C twice (exit)
tail -3 "$S" | grep -c hi                     # A) >0 → "hi" flushed on self-exit (no Glint bug there)
# now ⌘Q to quit Glint, reopen, then:
tail -3 "$S" | grep -c hi                     # B) compare — if the tail vanished only after ⌘Q → the quit-path bug
```
- "hi" present after self-exit (A) → upstream race, not Glint's kill (fix = `/quit` habit + upstream).
- "hi" present after self-exit but gone after ⌘Q (B) → **the Glint quit-teardown bug → fix #2.**

## Bottom line
Not data loss in storage, not the resume toggle. It's lost-tail-on-exit: a documented Claude Code
post-turn flush race that a graceful exit wins and an abrupt one loses. Glint's same-pane Ctrl+C
path is graceful (identical to a system terminal), but its **⌘Q quit path is not** — that's the one
Glint-side bug to fix; the rest is upstream.
