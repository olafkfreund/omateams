---
status: draft
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
   - `restart()` (`:496`) becomes `restart(automatic)`. First line:
     `if (automatic && Date.now() - startedAt < 60 * 1000) return`.
   - `checkMemory()`'s background recycle (`:318`) calls `win.recycle(true)`.
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
   - Replace `install -Dm755 "$build/omateams" "$bindir/omateams"` with:
     - `install -Dm755 "$build/omateams" "$bindir/omateams-unscoped"`;
     - a heredoc writing `$bindir/omateams`, mode 755, with exactly the
       wrapper in the spec's section C. It resolves `here` with
       `readlink -f "$0"`, because `~/.local/bin/omateams` is a symlink to it.
   - The `if_needed` shortcut (`:81`) also requires
     `-x $bindir/omateams-unscoped`.
   - The stamp already hashes `install.sh`, so an existing install rebuilds
     once.

   Verify:

   ```bash
   bash -n install.sh
   shellcheck install.sh
   ```

   Then, in a scratch copy:

   ```bash
   XDG_DATA_HOME=<tmp> ./install.sh
   ```

   This needs Qt dev tools; if they are missing, note it and leave this check
   to the owner.

6. **`README.md`: two notes.**
   - In the Memory section (`:158-171`), explain:
     - the ceiling restarts the window at 10 GiB of host plus page, even
       during a call and even with `memoryLimit: 0`;
     - after a screen share the window process is watched every 10 s and
       restarted rather than reloaded;
     - the `systemd-run` cap.
   - Fix the claim that `memoryLimit: 0` turns all of it off.
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
- Runtime: the spec's Verification list, steps 1 to 8, on Wayland with
  PipeWire. It needs a local build with low `ceiling` and `memoryLimit`
  values that is not committed. The owner runs it, or I do with their OK,
  since it needs a Teams sign-in and a screen share.
- After the owner's Qt bump: share and stop 5 times. Expect no
  `eglCreateSync failed`, flat host memory, and a clean quit.

## Rollback

- To undo everything, revert the implementation commits on
  `fix/host-memory-runaway`, or don't merge the branch.
- `install.sh` users: rerun `install.sh` from the previous release. It writes
  a real binary over the wrapper, and a leftover `bin/omateams-unscoped` is
  harmless.
