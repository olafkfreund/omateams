---
status: approved
issue: none (issues are disabled on this repo)
spec: spec/2026-11-17-host-memory-runaway.md
coders:
  1: codex   # small, tricky control flow: one restart path with a loop guard
  2: codex   # small, tricky ordering in checkMemory (ceiling before the recycling return, overdue)
  3: coder   # two small, mechanical edits in Media.js and reportMedia
  4: coder   # mechanical: reload call sites, CLI reply order, a comment
  5: coder   # shell wrapper in install.sh, its shape is written out below
  6: coder   # README text
reviewers:
  - codex    # independent read of the diff against this plan, beside the Opus review
---

# Plan: Stop the window process running away after a screen share

## Approved decisions (from the spec)

- **Root cause:** libwebrtc's `EglDmaBuf` destructor calls
  `EglTerminate(egl_.display)` on Mesa's shared display (QTBUG-142040). It is
  fixed in QtWebEngine 6.140.0 final; 6.140.0-rc and Qt 6.11/6.12 still have
  it.
- **Layer A, the Qt bump:** done in the owner's NixOS config, outside this
  repo and outside this plan. This repo only gets the README and comment
  notes (steps 4 and 6).
- **Layer B, the guard,** in `host/qml/Main.qml` and `host/qml/Media.js`:
  - one automatic-restart path with a 60 s loop guard;
  - a ceiling of **10 GiB on host plus page**, checked first;
  - an `overdue` recheck every 10 s;
  - a marker for every share attempt;
  - a 10 s timer after a share or while `overdue`;
  - `captured` reloads restart the host;
  - the CLI `reload` replies first.
- **Layer C, the cap:** `install.sh` installs a `systemd-run` scope wrapper,
  the same as the Nix package (`MemoryHigh=12G`, `MemoryMax=16G`,
  `MemorySwapMax=0`).
- **Owner decisions:**
  - the ceiling is 10 GiB on host plus page;
  - a listen-only call is an accepted exception above `hardLimit`;
  - the idle interval stays at 5 min.
- **Not in scope:**
  - a call signal based on peer connections;
  - a loop guard kept across processes;
  - Chromium flags;
  - carrying the Qt patch.

## Repo traps (apply to every step)

- `Sys.exitNow` is `::_exit`. After a share, never call `Qt.quit()` or a plain
  `view.reload()` on a captured host: the Chromium teardown dies with SIGTRAP.
- `Sys.processMemory(pid)` returns MiB (`VmRSS + VmSwap`), or `-1` when the
  pid is gone. Treat a negative reading as 0 in sums.
- QML runs on JavaScript without `let`-heavy features: follow the file's
  existing `var` and `function` style. Comments explain the why in one or two
  lines, in the file's plain-English voice.
- Line numbers are from commit `9515da7`. Re-find them with `grep` if earlier
  steps moved them.
- No new files except `plan/`. No new dependencies.

## Steps

1. **`host/qml/Main.qml`: one automatic-restart path.**
   - Add `readonly property real startedAt: Date.now()` beside `lastRescue`
     (around `:80`).
   - `recycle()` (`:375`) becomes `recycle(automatic)`. Its captured branch
     (`:377`) calls `restart(automatic)`.
   - `restart()` (`:496`) becomes `restart(automatic)`. When the call is
     automatic and the process is younger than 60 s, it does not drop the
     restart. It defers it:

     ```qml
     var wait = 60 * 1000 - (Date.now() - startedAt)
     if (automatic && wait > 0) { deferredRestart.interval = wait; deferredRestart.restart(); return }
     ```

     Add `Timer { id: deferredRestart; onTriggered: win.restart(true) }`
     beside the other timers.
   - The deferral refines the spec's "returns without acting". Otherwise a
     renderer crash in the first minute (the one-shot `reloadTimer`) would be
     lost and leave the page dead. The guard still holds: at most one
     automatic restart per minute.
   - `checkMemory()`'s background recycle (`:316`) calls `win.recycle(true)`.
     `rescue()`'s page branch (`:341`) calls `recycle(true)`.
   - `rescue()`'s last branch (`:342-347`) becomes `else { notice; restart(true) }`
     with the notice "Teams restarted / Its window process had grown to N GiB."
   - Delete `hostWarned` (`:84`, and its uses at `:342-344` and `:402`).

   Verify:

   ```bash
   grep -n hostWarned host/qml/Main.qml
   qmllint host/qml/Main.qml
   ```

   Expect no `hostWarned` lines and no new warnings.

2. **`host/qml/Main.qml`: ceiling, `overdue`, timer and status.**
   - Add `readonly property int ceiling: 10240` with a one-line comment: host
     and page together, below the 12 GiB cgroup throttle, independent of
     `memoryLimit`.
   - Change the start of `checkMemory()` (`:302-305`) so that both reads come
     first, then
     `if (Math.max(0, hostMemory) + Math.max(0, pageMemory) > ceiling) { memoryNotice(...); restart(true); return }`,
     then `if (recycling) return`.
   - The rest of the function is unchanged. Keep `pageMemory`, `hostMemory`
     and `statusTimer.restart()` updated.
   - After the baseline line, add the `overdue` handling. When `overdue` is
     set and host plus page is at or under `hardLimit`, clear `overdue` and
     return. When `overdue` is set and still over the limit, call `rescue()`
     and return. The existing `hardLimit` test stays as is.
   - Timer (`:661`): `interval: win.sharing || win.captured || win.overdue ? 10 * 1000 : 5 * 60 * 1000`.
     Update the comment above it.
   - `statusObject()` (`:231`): add `captured: captured` and
     `overdue: overdue`.

   Verify: run `qmllint`. Then read `checkMemory()` top to bottom and confirm
   this order: reads, ceiling, recycling return, baseline, `overdue`,
   `hardLimit`, background recycle.

3. **`host/qml/Media.js` and `reportMedia()`: share attempts.**
   - `Media.js` wrapper (`:46-52`): inside
     `navigator.mediaDevices[name] = function () {`, before the `return`, add
     the generated line
     `"      if (display) console.log(marker + 'attempt');\n"`.
   - `reportMedia()` (`Main.qml:358-367`): after the `MARKER` check, read
     `var state = message.slice(Media.MARKER.length)`. Then
     `if (state === "attempt") { captured = true; statusTimer.restart(); return }`.
     Then `var on = state === "on"`, with the rest unchanged.

   - **Subframes (approved spec contingency).** The media script runs with
     `runOnSubframes = false` (`Main.qml:213`). If runtime check 1 shows that
     a share attempt does not log `attempt`, Teams shares from a child frame.
     In that case set `runOnSubframes = true` for the media script. The
     script's `if (window.__omateamsInCall ...) return` already keeps it to
     one install per frame. This edit is made only on that evidence, and
     noted in the PR.

   Verify by printing the generated page script:

   ```bash
   node -e "$(sed 's/^\.pragma library//' host/qml/Media.js); console.log(pageScript())"
   ```

   It must contain `'attempt'` before `original.apply`, and the generated
   script must parse:

   ```bash
   node -e "$(sed 's/^\.pragma library//' host/qml/Media.js); new Function(pageScript())"
   ```

4. **`host/qml/Main.qml`: reload paths, CLI and comment.**
   - Ctrl+R/F5 (`:667`):
     `onActivated: win.captured ? win.recycle() : view.reload()`.
   - `reloadTimer` (`:635`):
     `onTriggered: win.captured ? win.recycle(true) : view.reload()`.
   - `reload` case (`:431`):
     `case "reload": Sys.reply(connection, "ok"); recycle(); break`.
   - `captured` comment (`:85-91`): add one line saying it is QTBUG-142040,
     fixed in QtWebEngine 6.140.0.

   Verify:

   ```bash
   qmllint host/qml/Main.qml
   grep -n 'view.reload()' host/qml/Main.qml
   ```

   The grep should list only the guarded call sites and the
   discard-failure path in `recycle()`.

5. **`install.sh`: scope wrapper.**
   - Replace `install -Dm755 "$build/omateams" "$bindir/omateams"` with the
     following. The delimiter is quoted, so `$0`, `$@` and the runtime path
     expand when the wrapper runs, not at install time. `readlink -f` is
     needed because `~/.local/bin/omateams` is a symlink to the wrapper.

     ```bash
     install -Dm755 "$build/omateams" "$bindir/omateams-unscoped"
     # The window runs in a memory-capped scope, so a runaway is stopped by the
     # kernel even if the app's own guard cannot (QTBUG-142040). Same limits as
     # the Nix package.
     cat > "$build/omateams-wrapper" <<'EOF'
     #!/bin/bash
     here=$(dirname "$(readlink -f "$0")")
     if [ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus" ]; then
       exec systemd-run --user --scope --collect --quiet \
         -p MemoryHigh=12G -p MemoryMax=16G -p MemorySwapMax=0 \
         -- "$here/omateams-unscoped" "$@"
     fi
     exec "$here/omateams-unscoped" "$@"
     EOF
     install -Dm755 "$build/omateams-wrapper" "$bindir/omateams"
     ```
   - The `if_needed` shortcut (`:81`) also requires
     `-x $bindir/omateams-unscoped`.
   - The stamp already hashes `install.sh`, so an existing install rebuilds
     once.

   Verify:

   ```bash
   bash -n install.sh
   shellcheck install.sh
   ```

   Then install into a throwaway `HOME`. `install.sh` writes
   `$HOME/.local/bin` and talks to the running instance's socket, so `HOME`,
   the data, config and runtime directories must all be isolated:

   ```bash
   t=$(mktemp -d)
   mkdir -p "$t/run"
   HOME="$t" XDG_DATA_HOME="$t/share" XDG_CONFIG_HOME="$t/config" XDG_RUNTIME_DIR="$t/run" ./install.sh
   test -x "$t/share/omateams/bin/omateams-unscoped" && test -x "$t/share/omateams/bin/omateams"
   HOME="$t" XDG_DATA_HOME="$t/share" XDG_CONFIG_HOME="$t/config" XDG_RUNTIME_DIR="$t/run" ./install.sh --if-needed; echo "exit=$?"
   ```

   - Expect the first run to install both files.
   - Expect the `--if-needed` rerun to exit 0 with no build, because the
     stamp is unchanged.
   - Then `rm "$t/share/omateams/bin/omateams-unscoped"` and rerun
     `--if-needed`. Expect a rebuild (exit 10).
   - `$t/run` has no bus socket, so the wrapper takes the unscoped fallback:
     `"$t/share/omateams/bin/omateams" --help` must print the usage.
   - Check the flag name against `install.sh`'s argument parsing first.
   - This needs `qmake6`. If it is missing, note it and leave this check to
     the owner.

6. **`README.md`: two notes.**
   - In the Memory section and the call/sharing paragraph after it
     (`:158-181`), explain:
     - the ceiling restarts the window at 10 GiB of host plus page, even
       during a call and even with `memoryLimit: 0`;
     - after a screen share the window process is watched every 10 s and
       restarted rather than reloaded;
     - the `systemd-run` cap.
   - Fix the claim that `memoryLimit: 0` turns all of it off.
   - Qualify "a call is left alone": above the ceiling it is not, and a
     listen-only call cannot be told from an idle page.
   - Change "fast checks while sharing" to "after any share attempt, or while
     a reload waits for a call to end".
   - Add a line: screen sharing on QtWebEngine older than 6.140.0 hits
     QTBUG-142040, and updating Qt is the real fix.

   Verify: read the section back.

7. **Lead (me): checks, review and commit.**
   - Run the static checks:

     ```bash
     qmllint host/qml/Main.qml
     node --test tests/
     bash -n install.sh
     grep -n hostWarned host/qml/Main.qml
     ```

   - Run the Opus review (fresh agent, given only this plan and `git diff`)
     and the Codex review.
   - Fix confirmed findings, then commit each step or a few steps together,
     naming the steps.

## Tests

- Static: the commands in step 7. Expect `qmllint` clean apart from warnings
  that were already there, theme tests green, `bash -n` clean, and no
  `hostWarned` lines.
- **Runtime, on Wayland with PipeWire.** These need a Teams sign-in and a
  screen share, so the owner runs them, or I do with their OK.
- **Setup.** Use a local build that is never committed:
  - `ceiling: 600` and `"memoryLimit": 200` in `settings.json`, so the
    limits are low enough to hit;
  - a `console.log("[guard]", hostMemory, pageMemory, overdue, captured)` at
    the top of `checkMemory()`.

  Watch it with:

  ```bash
  journalctl --user -f | grep -F '[guard]'
  omateams status | jq '{captured, overdue, hostMemory, memory}'
  ```

  1. **Attempts.**
     - Share, then cancel the picker: `captured` becomes true and `[guard]`
       lines come every 10 s.
     - In a new host, share and deny it in the portal: the same.
     - If neither shows `captured`, apply the subframe contingency in step 3.
  2. **Ceiling.** With the host older than 60 s, the next check passes 600
     MiB.
     - Expect one "Teams restarted" notice, a new pid in `status`, still
       signed in, and the same shown or hidden state.
     - `coredumpctl list omateams-unscoped` shows no new entry.
  3. **Ceiling during a call, a recycle, and `memoryLimit: 0`.** Each one
     restarts.
     - For the recycle case, trigger a background recycle by hiding the
       window with a low `memoryLimit`, then lower the ceiling below the
       current host.
  4. **Loop guard.** Keep the ceiling at 600 MiB so every new host passes it
     at once.
     - Restarts come about 60 s apart, never faster.
     - A user Ctrl+R in the first minute still acts at once.
     - `kill -9` the renderer pid in the first minute on a captured host:
       the restart is deferred and happens at 60 s.
  5. **Overdue.** For this test set `ceiling` above the call's size and
     `memoryLimit` low.
     - In a mic-only call, never shared, over `hardLimit`: one notice,
       `overdue: true`, and `[guard]` every 10 s.
     - Hang up: a reload or restart follows within 2.5 min.
     - Repeat, and raise `memoryLimit` in `settings.json` before hanging up
       so the pair is under `hardLimit`: `overdue` goes false and nothing
       reloads.
  6. **Reload paths.**
     - On a captured host, F5, Ctrl+R and `kill -9` of the renderer each
       restart (new pid).
     - On a fresh host they reload (same pid).
     - `omateams reload` prints `ok` on both.
     - Quit after a cancelled picker leaves no core.
  7. **Share after recovery.** After an automatic restart, sharing works.
  8. **Wrapper.**
     - Step 5's throwaway install checks.
     - On the real install, `systemctl --user status $(omateams status | jq .pid)`
       shows a `run-*.scope` with `MemoryMax=16G`.
     - After a restart, the new pid is in the same scope.
- After the owner's Qt bump: share and stop 5 times. Expect no
  `eglCreateSync failed`, flat host memory, and a clean quit.

## Rollback

- To undo everything, revert the implementation commits on
  `fix/host-memory-runaway`, or don't merge the branch.
- `install.sh` users: rerun `install.sh` from the previous release. It writes
  a real binary over the wrapper, and a leftover `bin/omateams-unscoped` is
  harmless.
