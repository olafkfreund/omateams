---
status: draft
issue: none (issues are disabled on this repo)
author: olafkfreund
---

# Intent: Stop the window process running away after a screen share

## Problem

After a screen share in omateams, the window (host) process can grow
without bound. In the incident on 2026-11-17 a share started at 13:18 and was
dropped at once; the host process (pid 35266) then grew to 180 GiB while the
Teams page itself stayed near 1.5 GiB.

QtWebEngine runs Chromium's GPU thread inside the host process. When a share
ends, Chromium's PipeWire capturer tears down the EGL display it shares with
that thread, and every later frame fails (described in `host/qml/Main.qml`
next to `captured`). That is what grows.

The memory guard in `host/qml/Main.qml` saw it and did not stop it:

1. When the host, not the page, is what grew, `rescue()` sends one
   notification, latches `hostWarned`, and never acts again.
2. `captured` is set only when `getDisplayMedia` succeeds, so a share that
   fails at once is not recorded. Reloads and quits then take the teardown
   path the code says dies with SIGTRAP.
3. Checks drop from every 10 s to every 5 min as soon as a share ends, which
   is when the growth starts.
4. A call in progress blocks every remedy, at any size. `overdue` is set and
   never acted on.
5. Ctrl+R/F5 and renderer-crash recovery reload the page directly, which
   keeps the broken host after a share.
6. `memoryLimit: 0` ("never reload the page") also switches off the hard
   limit, so nothing guards the host.

## Proposed outcome

- After any share attempt, successful or not, host growth is caught within
  seconds and the host is restarted automatically, the way a reload already
  restarts it today once `captured` is set.
- No call is dropped below a catastrophic size. Above it (16 GiB of host
  memory, agreed with the owner) the host restarts even during a call: the
  call is lost either way when the machine runs out of memory.
- Automatic restarts cannot loop.
- If research finds a way to stop the EGL teardown at its source (a Chromium
  flag, an upstream fix, a carried patch) or a hard cap outside the app, it is
  used as well, so the guard is the backstop rather than the only defence.

## Affected users and systems

- Anyone running omateams who shares the screen, on Wayland with PipeWire.
- Files: `host/qml/Main.qml`, `host/qml/Media.js`, possibly `host/main.cpp`
  (Chromium flags), `host/Bridge.cpp`, `ui/Service.qml` (how the host is
  launched).

## Constraints

- A call is never dropped below the catastrophic ceiling.
- A restart keeps the sign-in (profile on disk) and the window's shown or
  hidden state, as `restart()` does today.
- Screen sharing must keep working.
- After a share, never take Chromium's normal teardown (SIGTRAP and core dump).
- The smallest change that closes each gap; no new dependencies.

## Open questions

1. Which root-cause fix, if any, the research supports: Chromium flag,
   upstream Qt/Chromium version, carried patch, or a systemd `MemoryMax` cap.
   This is settled in the spec.
2. The in-call check sees only local microphone, camera or screen tracks, so
   a listen-only call looks idle and an automatic restart would drop it. Is
   that acceptable, or must the spec find a better call signal?
3. Should the check stay at every 5 min when nothing was shared, or move to
   60 s?
