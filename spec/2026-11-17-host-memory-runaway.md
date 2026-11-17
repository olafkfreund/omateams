---
status: approved
issue: none (issues are disabled on this repo)
intent: intent/2026-11-17-host-memory-runaway.md
---

# Spec: Stop the window process running away after a screen share

## Root cause (verified)

- libwebrtc builds a new `EglDmaBuf` for every screen-cast stream
  (`shared_screencast_stream.cc`, `StartScreenCastStream`). It opens Mesa's
  default Wayland EGL display, and its destructor calls
  `EglTerminate(egl_.display)`.
- Mesa returns one display per platform and native display, and
  `eglTerminate` has no reference count, so ending a share terminates the
  display that QtWebEngine's in-process GPU thread also uses. That thread runs
  in our host process.
- Upstream: QTBUG-142040, "Webengine crashes on toggling screen sharing"
  (Hyprland and NixOS among the reports, `eglCreateSync failed 0x3001`). It
  is fixed by `qtwebengine-chromium` commit `0f809e88`, a backport of
  webrtc `dd679612`, which deletes the `EglTerminate` call.
- Checked against code.qt.io:
  - The `v6.140.0` tag pins Chromium `e2b413ea`. Its `egl_dmabuf.cc` has no
    `EglTerminate(egl_.display)`.
  - The `v6.140.0-rc` tag pins `39352427`, which still has it. That is the
    version this machine runs: the installed omateams 1.4.1 links
    `qtwebengine-6.140.0-rc`.
  - The 6.11 and 6.12 branches do not have the fix (Fable's research; not
    rechecked here).
- Not established: how the terminated display becomes 180 GiB of host
  memory. No flag avoids the bug. Forcing shared-memory buffers does not help,
  because the display is created and terminated whatever the buffer type.

## Design

Three layers. The first removes the cause. The other two are needed because
`install.sh` users build against the distro's `qt6-webengine` (Arch, 6.11.x),
which keeps the bug until Qt ships a fixed release, and because the growth
mechanism is unknown.

### A. Move to QtWebEngine 6.140.0 final (outside this repo)

- In the owner's NixOS configuration (`pkgs/omateams/default.nix` and the Qt
  set it builds against), move from `6.140.0-rc` to `6.140.0` or later.
- This repo gets two notes:
  - the README: screen sharing on QtWebEngine older than 6.140.0 hits
    QTBUG-142040;
  - the `captured` comment in `host/qml/Main.qml:85-91`: the bug id and
    "fixed in 6.140.0".
- The workaround stays. It costs nothing on a fixed Qt.

### B. In-app guard (`host/qml/Main.qml`, `host/qml/Media.js`)

1. **One automatic-restart path with one loop guard.**
   - `recycle(automatic)` passes the flag on to `restart(automatic)`.
   - `restart(automatic)` returns without acting if `automatic` and the
     process is younger than 60 s (`startedAt`, set once at start).
   - Every automatic caller passes `true`: `rescue()`, `checkMemory()`'s
     background recycle, the ceiling, and renderer-crash recovery. User
     actions (Ctrl+R/F5, `omateams reload`, the bar) pass nothing and are
     never blocked.
   - Effect: an automatic restart happens at most once per minute. A host that
     keeps passing a limit within a minute of starting restarts once a minute.
     That is accepted; the alternative is unbounded growth. No state carries
     across processes.
2. **`rescue()`'s last branch restarts.** `Main.qml:342-346` calls
   `restart(true)` with a notice instead of the latched warning, and
   `hostWarned` (`:84`, `:344`, `:402`) is removed.
3. **Catastrophic ceiling, before anything else in `checkMemory()`.**
   - `readonly property int ceiling` (MiB). The value is open question 1.
   - Measured on the host and renderer together. The external cap (C)
     charges both to the same cgroup, so a host-only ceiling can be passed by
     the pair while neither half crosses it.
   - At the top of `checkMemory()`, before `if (recycling) return`
     (`:303`): read both processes, then
     `if (hostMemory + pageMemory > ceiling) { notice; restart(true); return }`.
   - It is synchronous and never waits on `view.runJavaScript`, so a page
     that doesn't answer cannot block it. It acts during a page recycle and
     during a call. Dropping the call is allowed above the ceiling.
   - It ignores `memoryLimit`, so `memoryLimit: 0` keeps it, which closes
     intent gap 6.
   - It uses the same `VmRSS + VmSwap` reading as today
     (`Bridge.cpp:182-201`).
   - Between two checks, memory can still pass the external cap; C is the
     backstop for that.
4. **Deferred restart after a call.**
   - `memoryTimer` runs at 10 s while `overdue`, as well as after a share
     (item 6).
   - While `overdue`, `checkMemory()` compares host plus page against
     `hardLimit`:
     - still over: it calls `rescue()`. Once the call is over, that lands in
       a non-call branch (reload, or restart when captured or when the host is
       what grew).
     - back under: it clears `overdue` and does nothing.
   - Latency after hang-up is at most 10 s plus `rescueSpacingMs` (2 min).
5. **Share attempts count, in the main frame.**
   - In the `Media.js` wrapper, before `original.apply(...)` when `display`
     is true, log `marker + 'attempt'`.
   - `reportMedia()` handles `attempt` before the `on === sharing` early
     return (`Main.qml:362`): it sets `captured = true` and changes nothing
     else.
   - The media script runs in the main frame only (`runOnSubframes = false`,
     `:213`). An attempt from a child frame is not seen. Verification step 1
     checks which frame Teams shares from. If it is a child frame,
     `runOnSubframes` becomes `true` for this script. The script already
     guards against running twice per window.
   - A cancelled picker also sets `captured`. The only cost is that a later
     reload becomes a restart.
   - `captured` and `overdue` are added to `statusObject()` (`:231`), so
     `omateams status` can show them.
6. **Check interval:** `memoryTimer` (`:661`) uses
   `sharing || captured || overdue ? 10 s : 5 min`.
7. **User reloads on a captured host restart it.** Ctrl+R/F5 (`:667`) calls
   `captured ? recycle() : view.reload()`. Renderer-crash recovery
   (`reloadTimer`, `:635`) does the same with `recycle(true)`.
8. **CLI reply first.** The `reload` case (`:431`) replies before
   `recycle()`. Today a captured host `_exit`s first, so the CLI reports not
   running.

### C. Memory cap outside the app for `install.sh` builds

- The Nix package already does this
  (`~/.config/nixos-omateams-cap/pkgs/omateams/default.nix:78`). The cap was
  added at 13:29, after the incident: pid 35266 started at 13:04 without it.
- `install.sh` installs the built binary as `bin/omateams-unscoped`, plus a
  `bin/omateams` script with the same logic:

  ```bash
  #!/bin/bash
  here=$(dirname "$(readlink -f "$0")")
  if [ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus" ]; then
    exec systemd-run --user --scope --collect --quiet \
      -p MemoryHigh=12G -p MemoryMax=16G -p MemorySwapMax=0 \
      -- "$here/omateams-unscoped" "$@"
  fi
  exec "$here/omateams-unscoped" "$@"
  ```

- The wrapper forwards arguments, output and exit status through `exec`.
- `ui/Service.qml` is unchanged, because it already launches `bin/omateams`.
  Its install check (`:186`) tests only the wrapper. So `install.sh`'s
  "stamp is current, nothing to do" shortcut must also require
  `bin/omateams-unscoped`, so that a missing payload triggers a rebuild.
- `restart()` launches `Sys.executable()`, the unscoped binary, as a child of
  the host. The child stays in the same scope. A scope ends only when its
  last process exits, and the new host is that process.
- Short commands such as `show` and `quit` also run in a short-lived scope,
  as they already do under Nix.

## Alternatives rejected

- **Chromium flags** (`--disable-gpu`, `--disable-gpu-compositing`,
  `--use-gl=egl`, `EGL_PLATFORM=surfaceless`): none is shown to avoid the
  terminate call, and `--disable-gpu` makes Teams calls software-rendered.
- **Disabling `WebRTCPipeWireCapturer`:** breaks Wayland screen sharing.
- **Carrying the 3-line patch in a QtWebEngine overlay:** this means a
  multi-hour rebuild, and 6.140.0 final already contains the fix. It's only
  worth it if the bump in A is blocked.
- **A loop guard persisted across processes:** more code, and the only
  failure it prevents (one restart per minute) is benign next to the leak.
- **Host-only ceiling:** misses the case where host and page together pass
  the cgroup cap.
- **Host-side `onPermissionRequested` signal:** unconfirmed for desktop
  capture. The marker plus the subframe check covers it.
- **A new in-call signal (`RTCPeerConnection` state):** untested, and may
  read "in call" for idle connections Teams keeps open. See open question 2.
- **`RLIMIT_AS`:** limits address space, not resident memory, and breaks
  Chromium.

## Risks

- **Listen-only calls.** The in-call check sees only local tracks, so above
  `hardLimit` a listen-only call is reloaded or restarted. That is already
  today's behaviour for page growth, and it conflicts with the intent's
  constraint unless the owner accepts it (open question 2).
- **Polling gap.** Growth faster than 10 s per step can pass the cgroup cap
  before the ceiling fires. Then the kernel kills Teams, and nothing restarts
  it until the bar or the user starts it again.
- **Growth mechanism unknown.** On an unfixed Qt, growth could in principle
  start without a recorded attempt. C and the hard limit still apply.
- **One restart a minute** in the worst case, if the host grows straight back.
- **10 s checks after a share** until the next restart: two `/proc` reads per
  tick.

## Verification

Temporary instrumentation for the runtime steps: a local, uncommitted build
with low `ceiling` and `memoryLimit` values and a `console.log` in
`checkMemory()`. Watch it with `journalctl --user -f` and
`omateams status`, which now shows `captured` and `overdue`.

- **Static:**
  - `qmllint host/qml/Main.qml`
  - `install.sh` build
  - `node --test tests/` (unrelated theme tests, must stay green)
  - `grep -n hostWarned host/qml/Main.qml` returns nothing
- **Runtime, Wayland with PipeWire:**
  1. **Attempts.** Share and cancel the picker, then share and have it fail
     (deny in the portal). Each time `captured` is true and the checks run at
     10 s. Note whether the marker came from the main frame; if not, apply the
     subframe change in B5.
  2. **Ceiling.** Process older than 60 s, over the ceiling: restart, the
     sign-in kept, shown or hidden state kept, and no new omateams entry in
     `coredumpctl list`.
  3. **Ceiling in special states.** During a live call: it restarts. While a
     page recycle is under way: it restarts. With `memoryLimit: 0`: it
     restarts.
  4. **Loop guard.** Keep the low ceiling so each new host passes it at once.
     Expect one restart per minute, never faster. User Ctrl+R inside the
     first minute still works.
  5. **Overdue.** In a mic-only call, never shared, over `hardLimit` but
     under the ceiling: one notice and `overdue` true. After hanging up, a
     reload or restart within 2.5 min. Repeat with memory dropping below
     `hardLimit` before hang-up: `overdue` clears and nothing happens.
  6. **Reload paths.** Captured host: F5, Ctrl+R and a renderer kill
     (`kill -9` the renderer pid from status) each restart. Fresh host: they
     reload. `omateams reload` prints `ok`. Quit after a cancelled picker
     exits without a core.
  7. **Share after recovery.** After an automatic restart, share again and
     confirm it works.
  8. **`install.sh` wrapper.**
     - Fresh build: both files present.
     - Rerun with the stamp unchanged: no rebuild.
     - Plugin hidden autostart, `show`, `status` and `quit` give their usual
       replies.
     - `systemctl --user status` shows the host in a `run-*.scope` with
       `MemoryMax`, and after an automatic restart the new pid is in the same
       scope.
     - With `XDG_RUNTIME_DIR` pointing at an empty directory, it runs
       unscoped.
- **On 6.140.0 final (after A):** share, stop, share again 5 times. Expect no
  `eglCreateSync failed` in the journal, flat host memory, and a clean
  `omateams quit`.

## Open questions

1. **Ceiling value.** You agreed 16 GiB of host memory, but the cgroup cap
   kills host and page together at 16 GiB and throttles them at 12 GiB, so a
   16 GiB ceiling never fires.
   - Recommendation: host plus page at **10 GiB**, below the throttle.
   - Alternative: keep 16 GiB and raise the caps (for example `MemoryHigh=20G`,
     `MemoryMax=24G`).
2. **Listen-only calls.** The constraint says no call is dropped below the
   ceiling, but the guard can't see a listen-only call.
   - Recommendation: accept it as an explicit exception, which is current
     behaviour.
   - Alternative: build and test a peer-connection call signal first.
3. **Idle check interval.** Keep 5 min when nothing was shared and no call is
   overdue (recommended). Growth has only been seen after a share.
