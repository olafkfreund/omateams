---
status: draft
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
which keeps the bug until Qt ships a fixed release.

### A. Move to QtWebEngine 6.140.0 final (outside this repo)

- Bump the Qt package set the omateams Nix package builds against, in the
  owner's NixOS configuration, from `6.140.0-rc` to `6.140.0` or later.
- This repo only gets a README note: screen sharing on QtWebEngine older than
  6.140.0 hits QTBUG-142040.
- The `captured` comment in `host/qml/Main.qml:85-91` gets the bug id and
  "fixed in 6.140.0". The workaround stays, because it costs nothing on a
  fixed Qt.

### B. In-app guard (`host/qml/Main.qml`, `host/qml/Media.js`)

1. **Restart instead of warning.**
   - New `autoRestart()`. It returns if the process is younger than 60 s
     (`startedAt`, set once at start). Otherwise it calls `memoryNotice()`
     and the existing `restart()` (`Main.qml:496`).
   - `rescue()`'s last branch (`Main.qml:342-346`) calls `autoRestart()`
     instead of the latched notice.
   - `hostWarned` (`:84`, `:344`, `:402`) is removed.
   - The loop guard is 60 s, not 5 min. A fresh host cannot pass the limits
     in 60 s, and a longer guard would leave a fresh host unprotected after
     every restart.
2. **Catastrophic ceiling, independent of the page and of `memoryLimit`.**
   - `readonly property int hostLimit` (MiB). The value is open question 1.
   - In `checkMemory()`, right after `hostMemory` is read (`:305`):
     `if (hostMemory > hostLimit) { autoRestart(); return }`.
   - It is synchronous and never waits on `view.runJavaScript`, so a page
     that doesn't answer cannot block it. It restarts during a call, as the
     intent allows above the ceiling.
   - It runs even with `memoryLimit: 0`, which closes intent gap 6.
   - It measures the host process alone, using the same `VmRSS + VmSwap` as
     the existing checks (`Bridge.cpp:182-201`).
3. **Deferred restart after a call.**
   - `checkMemory()` also calls `rescue()` while `overdue` is set.
   - Once the call ends, `rescue()` lands in a non-call branch: a reload, or
     a restart when `captured`, or `autoRestart()` when the host is what grew.
   - If both processes are back under `hardLimit`, `overdue` is cleared and
     nothing happens.
   - Latency is up to `rescueSpacingMs` (2 min) after the call ends.
4. **Every share attempt counts.**
   - In the `Media.js` wrapper, before `original.apply(...)` when
     `display` is true: `console.log(marker + 'attempt')`.
   - `reportMedia()` handles `attempt` before the `on === sharing` early
     return (`Main.qml:361`): it sets `captured = true` and changes nothing
     else.
   - No host-side permission hook. It is not known that `permissionRequested`
     fires for screen capture, and the marker covers the case on its own.
   - A cancelled picker also sets `captured`. That is accepted: the only cost
     is that a later reload becomes a restart.
5. **Keep checking after a share.**
   - `memoryTimer` interval becomes `win.sharing || win.captured ? 10 s : 5 min`
     (`:661`).
   - Worst-case detection after a share is 10 s plus the restart time.
6. **Reloads on a captured host restart it.**
   - Ctrl+R/F5 (`:667`) and the renderer-crash `reloadTimer` (`:635`) call
     `captured ? recycle() : view.reload()`.
   - A host that never shared keeps the plain reload.
7. **CLI reply first.**
   - The `reload` case (`:431`) replies before `recycle()`.
   - Today a captured host `_exit`s first and the CLI reports not running.

### C. Memory cap outside the app for `install.sh` builds

- The Nix package already starts the host in
  `systemd-run --user --scope --collect -p MemoryHigh=12G -p MemoryMax=16G -p MemorySwapMax=0`
  when the user bus exists. That cap was added after the incident: pid 35266
  started at 13:04 without it.
- `install.sh` installs the built binary as `bin/omateams-unscoped`, plus a
  `bin/omateams` script with the same `systemd-run` line and the same fallback
  to a plain `exec` when there is no user bus.
- The script takes its limits from the Nix wrapper so both installs behave
  alike. `ui/Service.qml` is unchanged, because it already launches
  `bin/omateams`.
- Short commands such as `show` and `quit` also run in a short-lived scope,
  as they already do under Nix.

## Alternatives rejected

- **Chromium flags** (`--disable-gpu`, `--disable-gpu-compositing`,
  `--use-gl=egl`, `EGL_PLATFORM=surfaceless`): none is shown to avoid the
  terminate call, and `--disable-gpu` makes Teams calls software-rendered.
- **Disabling `WebRTCPipeWireCapturer`:** breaks Wayland screen sharing,
  which the intent requires.
- **Carrying the 3-line patch in a QtWebEngine overlay:** this means a
  multi-hour QtWebEngine rebuild, and 6.140.0 final already contains the fix.
  It's only worth it if the bump in A is blocked.
- **Host-side `onPermissionRequested` signal:** unconfirmed for desktop
  capture. The Media.js marker is enough.
- **A new in-call signal (`RTCPeerConnection` state):** untested, and it may
  read "in call" for idle connections Teams keeps open. See open question 2.
- **`RLIMIT_AS`:** limits address space, not resident memory, and breaks
  Chromium's large reservations.
- **5-minute loop guard:** it would leave every fresh host unprotected for 5
  minutes after each restart.

## Risks

- **The ceiling and the Nix cap interact.** Under the Nix wrapper the cgroup
  (host plus renderer) is throttled at 12 GiB and killed at 16 GiB, so a
  16 GiB host-only ceiling would never fire. In a call, the kernel would kill
  Teams with SIGKILL and nothing would restart it. See open question 1.
- **Listen-only calls.** The in-call check sees only local tracks, so a
  listen-only call over `hardLimit` (8 GiB combined) is reloaded or restarted.
  That is already today's behaviour for page growth; the change extends it to
  host growth.
- **Growth mechanism unknown.** On an unfixed Qt, growth could in principle
  start without a recorded share attempt. The cap in C and the hard limit
  still apply.
- **A restart drops any call.** This is accepted only above the ceiling, or
  after a call ends.
- **Every check after a share runs at 10 s until the next restart:** two
  `/proc` reads per tick.

## Verification

- **Static:**
  - `qmllint host/qml/Main.qml`
  - build with `install.sh`
  - `node --test tests/` for the existing theme tests (unrelated, must stay
    green)
  - `grep -n hostWarned host/qml/Main.qml` returns nothing
- **Runtime on Wayland with PipeWire,** using a local build with a temporary
  low `hostLimit` (a few hundred MiB) and `hardLimit`, not committed:
  1. Start a share and cancel the picker. The status shows `captured`, and
     the logged checks run every 10 s.
  2. Host over `hostLimit`, process older than 60 s: the host restarts, keeps
     the sign-in and its shown or hidden state, and `coredumpctl list` shows
     no new omateams core.
  3. The same during a live call: it restarts.
  4. The same within 60 s of start: no restart (loop guard).
  5. With `memoryLimit: 0`: the ceiling still restarts.
  6. In a call over `hardLimit`: one notice. After hanging up, a restart or
     reload follows within 2 min.
  7. Ctrl+R on a captured host restarts it. On a fresh host it reloads.
     `omateams reload` prints `ok`.
  8. `install.sh` build: `systemctl --user status` shows the host in a
     `run-*.scope` with `MemoryMax`.
- **On 6.140.0 final (after A):** share, stop, share again 5 times. Expect no
  `eglCreateSync failed` in the journal, flat host memory, and a clean
  `omateams quit`.

## Open questions

1. **Ceiling value.** The agreed 16 GiB host-only ceiling cannot fire under
   the Nix cap (throttled at 12 GiB, killed at 16 GiB for both processes
   together). Recommendation: `hostLimit` = 10 GiB, so the app restarts
   cleanly before the cgroup throttles. The alternative is to raise the Nix
   cap above 16 GiB.
2. **Listen-only calls.** Accept that they look idle above `hardLimit`, which
   is current behaviour (recommended), or build a peer-connection signal.
3. **Idle check interval.** Keep 5 min when nothing was shared (recommended).
   Growth has only been seen after a share.
