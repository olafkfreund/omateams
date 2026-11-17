---
status: draft
issue: none (issues are disabled on this repo)
intent: intent/2026-11-17-host-swap-stale-binary.md
---

# Spec: Swap a hidden Teams window onto the build that was just installed

## Owner decision (from the intent approval)

Scope is version changes only. A rebuild with the same version still needs a
manual restart.

## Cause (established as far as the evidence goes)

### The shell keeps a plugin's code for its whole life

The shell is omarchy-edge, `share/omarchy/shell/shell.qml`.

- **The plugin is loaded through an unchanging path.**
  `~/.config/omarchy/plugins/omateams` is a symlink to the packaged plugin.
  A deploy changes where it points (checked: it now points at
  `…-omateams-1.4.2/share/omateams/plugin`), but the path itself stays
  the same.
- **A rescan keeps the old instance.** On a change, `_syncServices()`
  either keeps the running Service instance and hands it the new manifest
  (`:1023-1027`, "A kept instance outlives the rescan; hand it the fresh
  manifest"), or runs a full reload (`reloadPlugins()`, `:1085`). That reload
  calls `Qt.clearComponentCache()`, which drops only components nothing
  references any more.
- **Either way the code comes from the same place.** The new instance is
  created from the same URL inside a long-running process, so it can get the
  compiled type the process first loaded.

### The two incidents match the shells' start times, not the deploys

| Host | Shell started | Plugin then | Swap launched |
|---|---|---|---|
| p620 | 19:01 | flake 1.4.1 (`zvgsgb30`) | `zvgsgb30` |
| razer | about 16:41 (shell restart, posted on the agent bus) | pre-flake `pkgs/omateams` (`z8cbr13m`) | `z8cbr13m` |

The plugin did see the new version, because the manifest comes from the
shell. It then launched the `hostBinary` from its own code.

### Ruled out

- **The Qt disk cache.** No file in `~/.cache/quickshell/qmlcache` holds an
  omateams store path. Also, p620 would then have launched the pre-flake
  build too, and it didn't.
- **The new package's `Service.qml`.** It holds the 1.4.2 path (checked on
  disk).

### Consequence

A fix in `Service.qml` takes effect only after the shell restarts once. From
then on, whatever plugin code runs, the swap must not rely on a store path
compiled into that code.

## Design

### Change: `ui/Service.qml` launches the host by command name

- **The first argument becomes `omateams`, resolved on `PATH`.** It falls
  back to `hostBinary` when `omateams` isn't on `PATH`. A small helper does
  this:

  ```qml
  // The plugin's code can outlive several updates in a running shell, so a
  // store path baked into it may be an old build. The omateams on PATH is
  // the one the last update installed; hostBinary is the fallback.
  function hostCommand(args) {
    return ["sh", "-c", 'b=$(command -v omateams) || b="$0"; exec "$b" "$@"', hostBinary].concat(args)
  }
  ```

- **Every launch uses it:**

  | Where | Becomes |
  |---|---|
  | `maybeAutostart()` (`:93`) | `Quickshell.execDetached(hostCommand(["--hidden"]))` |
  | `command()` (`:107`) | `Quickshell.execDetached(hostCommand([name]))` |
  | `maybeReplaceHost()` (`:174`) | `Quickshell.execDetached(["sh", "-c", 'b=$(command -v omateams) || b="$0"; "$b" quit; sleep 2; exec "$b" --hidden', hostBinary])` |

- **Unchanged:**
  - **When a swap happens.** It still needs a hidden window, a version
    mismatch, and is attempted at most once per instance.
  - **`installCheck`** (`:186`, `test -x hostBinary`).
  - **`nix/package.nix`.** Its `hostBinary` substitution stays and is now
    only the fallback.
- **What `omateams` on `PATH` resolves to:**
  - Nix with home-manager: `/etc/profiles/per-user/<user>/bin/omateams`,
    which every switch updates. It is in the shell's `PATH` (checked on
    p620).
  - The NixOS module: `/run/current-system/sw/bin/omateams`.
  - `install.sh`: `~/.local/bin/omateams`, a symlink to the stable
    `bin/omateams`. Without `~/.local/bin` on `PATH`, it falls back to the
    stable `hostBinary`, so nothing changes for those users.

### Restart loop

The swap still lands on whatever `omateams` is on `PATH`, and that is the
build the manifest came with.

- If it somehow landed on the same old version, the instance that did the
  swap has `replaceAttempted` set, so it won't swap again.
- A new instance comes only from a rescan or reload, which only a change to
  the plugin's files triggers. So there is no loop.

### Version

- `manifest.json` goes to **1.4.3**.
- The README's "Updating" section changes:
  - after an update that changes the version, the hidden window moves to the
    new build by itself;
  - after the first update to 1.4.3, restart the shell once (or log out and
    in), so the fixed plugin code is the one running;
  - a rebuild that keeps the same version still needs
    `omateams quit && omateams --hidden`.

### Rollout (owner pre-approved deploy)

1. Release 1.4.3, then a lock bump PR in nixos_config, merged.
2. Deploy p620 and razer from `main`, after checking with the agent bus.
3. On each host, restart the shell once (announced on the bus; the bar
   blinks), then restart omateams onto 1.4.3.

## Alternatives rejected

- **Making the shell reload plugin code properly** (for example a fresh URL
  per store path, or trimming the engine cache). That is upstream
  omarchy-edge work, outside this repo.
- **Substituting a different path in `nix/package.nix`,** such as a profile
  path. It depends on the user and setup, while `PATH` already covers every
  setup.
- **Having the host binary restart itself on a version change.** That would
  mean new logic in the host and new triggers, and the intent rules out
  widening when a swap happens.
- **Always running `command -v omateams` and dropping `hostBinary`.** That
  would break `install.sh` users without `~/.local/bin` on `PATH`. Keeping
  `hostBinary` as the fallback is the same amount of code.

## Risks

- **A different omateams on `PATH`** (for example an old `nix profile`
  install that comes first) would be launched instead. It is visible in the
  checks, because the running exe is compared with the expected one.
- **The `sh` wrapper costs one extra process per launch.** That is
  negligible, and `exec` replaces it.
- **Root cause still partly inferred.** The table and the shell code fit,
  but the engine's type cache wasn't traced.
- **The rollout restarts the shell** (the bar blinks), and an omateams
  restart drops any call.

## Verification

- **Static:**
  - `qmllint ui/Service.qml` shows no new warnings compared with `master`.
  - `nix flake check` passes.
  - `grep -n 'execDetached(\[hostBinary' ui/Service.qml` finds nothing.
- **Unit-level, in a shell:** the launch snippet, run with `PATH` with and
  without an `omateams`, picks the `PATH` one, and falls back to the given
  path. Check that with a fake `omateams` script.
- **Runtime on p620, after deploy and the shell restart:**
  1. Start an **older** host by hand, hidden, with
     `/nix/store/bfq4g8v6…-omateams-1.4.2/bin/omateams --hidden`.
     Within a status update (at most about 60 s), the plugin swaps it, and
     the running exe becomes the 1.4.3 `.omateams-wrapped` from the user
     profile.
  2. No second swap: `omateams status` keeps the same pid for 3 minutes
     after that.
  3. The bar's toggle (`command`) opens the 1.4.3 window.
  4. `coredumpctl` shows no new omateams entry.
- **Runtime on razer:** after the shell restart, Teams runs 1.4.3, and the
  same older-host test passes.

## Open questions

None.
