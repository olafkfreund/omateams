---
status: draft
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
- **Cause.** The Nix package bakes its own store path into `Service.qml`
  as `hostBinary`: the 1.4.2 plugin holds the 1.4.2 path. The version
  check that triggers the swap reads the new `manifest.json`. But the swap
  runs in a plugin instance that still holds an older `hostBinary`, so it
  launches the old binary.
  - Evidence: the swap came 3 s after the reload, and the binary it started
    is in no current profile.
  - Which instance runs it, and why, is inferred. The shell's internals
    weren't traced.
- **Why it matters.** A window left on an old build misses whatever the
  update fixed. Today that means the memory guard and QtWebEngine 6.140.0
  (QTBUG-142040). razer ran an unguarded, uncapped build for 10 days, and
  until this is fixed every deploy needs a manual
  `omateams quit && omateams --hidden`.

## Proposed outcome

- **The new build after an update.** Once an update installs a new version,
  a hidden Teams window ends up on that build, with no manual step, on Nix
  and on `install.sh`.
- **Visible windows are left alone,** as today; they pick up the new build
  on their next start.
- **No restart loop.** The swap happens at most once per update, and never
  repeatedly.

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

- **Visible windows:** never replace a window the user can see. Keep
  today's `windowVisible` check.
- **Calls:** a swap drops a running call. Don't make the swap happen in
  more situations than today; only the binary it launches is wrong.
- **Restart loop:** a swap that lands on the same version again must not
  trigger another one.
- **The first deploy:** the running plugin instances still have the bug, so
  the deploy that ships the fix needs one more manual restart. After that,
  later updates must swap correctly on their own.
- **Small change:** the smallest change that fixes it, with no new
  dependencies.

## Open questions

None. The approach (a stable launch path, a different trigger, or patching
the package) is for the spec.
