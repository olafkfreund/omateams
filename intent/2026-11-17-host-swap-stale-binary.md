---
status: approved
issue: none (issues are disabled on this repo)
author: olafkfreund
related: intent/2026-11-17-host-memory-runaway.md, intent/2026-11-17-nix-flake.md
---

# Intent: Swap a hidden Teams window onto the build that was just installed

## Problem

- **A deploy leaves the old build running.** After an omateams update, the
  plugin is meant to replace a hidden Teams window with the new build
  (`ui/Service.qml`, `maybeReplaceHost()`). On Nix it replaces it with the
  **old** build instead.
- **Observed on 2026-11-17, deploying 1.4.1 → 1.4.2:**
  - p620: the shell reloaded the plugin at 19:22:48, and the window was
    swapped at 19:22:51, onto `zvgsgb30…-omateams-1.4.1`.
  - razer: it was swapped at 19:27:53, onto `z8cbr13m…-omateams-1.4.1`.
    That is the pre-flake package from before #3037.
  - Both had to be restarted by hand onto 1.4.2.
- **Suspected cause, not established.** The Nix package bakes its own
  store path into `Service.qml` as `hostBinary` (`nix/package.nix:35-38`,
  `:61-63`). The 1.4.2 plugin holds the 1.4.2 path, which was checked on
  disk.
  - The swap needs the shell-supplied `manifest` (`Service.qml:15-18`) to
    report a different version than the host (`:169-174`).
  - So some instance saw version 1.4.2 while holding an older
    `hostBinary`. Candidates:
    - an old instance that got the new manifest;
    - a new instance that loaded old QML through a stale plugin link;
    - a swap already queued before the reload. That still has to be a
      different swap, because the host version and the manifest matched
      before the deploy.
  - The 3 s timing fits the command's own `sleep 2`, so it doesn't say
    which instance it was. The spec has to pin this down before choosing a
    fix.
- **Why it matters.** A window left on an old build misses whatever the
  update fixed. Today that means the memory guard and QtWebEngine 6.140.0
  (QTBUG-142040). razer ran an unguarded, uncapped build for 10 days, and
  until this is fixed every deploy needs a manual
  `omateams quit && omateams --hidden`.

## Proposed outcome

- **The new build after an update.** Once an update installs a new
  **version**, a hidden Teams window ends up on that build, with no manual
  step, on Nix and on `install.sh`. The check is that the running exe is the
  installed one.
- **Visible windows are left alone,** with today's eligibility rules; they
  pick up the new build on their next start.
- **No repeated disruption.** If a swap fails or lands on the same old
  version, the window isn't restarted again and again, including across
  plugin reloads.

## Affected users and systems

- **This repo:** `ui/Service.qml`. Possibly `nix/package.nix`, if the fix
  is in what the package substitutes. `manifest.json` gets a version bump,
  so that the fix is itself delivered by a swap.
- **The owner's NixOS config:** a lock bump of `omateams`, then a deploy to
  p620 and razer. The owner pre-approved the deploy ("deploy when ready").
- **`install.sh` users:** their `hostBinary` is a stable path
  (`~/.local/share/omateams/bin/omateams`), so they are not affected now and
  must not regress.

## Constraints

- **When a swap happens:** don't widen it. Keep today's checks (hidden
  window by the latest status, version mismatch, once per instance). This
  task fixes which binary a swap launches, not when one happens.
  - The window can become visible between that check and the `quit`; that
    window of time stays as it is.
  - A call still drops on a swap, as today.
- **Restart loop:** a swap that lands on the same version again must not
  trigger another one.
- **The first deploy:** if the cause is old plugin instances, the deploy that
  ships the fix may need one more manual restart. After that, later updates
  must swap correctly on their own.
- **Small change:** the smallest change that fixes it, with no new
  dependencies.

## Open questions

1. **Scope.** Should a rebuild with the **same** version, which `install.sh`
   does for source or Qt changes, also swap the window? The recommendation is
   no: keep the scope to version changes, as the swap is designed today.
   Same-version rebuilds keep needing a manual restart, as the README says.

Which plugin instance issued the launch is for the spec to establish, with
evidence. So is the approach: a stable launch path, a different trigger, or a
different package substitution.
