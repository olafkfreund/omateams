---
status: approved
issue: none (issues are disabled on this repo)
intent: intent/2026-11-17-host-swap-stale-binary.md
---

# Spec: Swap a hidden Teams window onto the build that was just installed

## Owner decision (from the intent approval)

Scope is version changes only. A rebuild with the same version still needs a
manual restart.

## Cause (partly established)

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

### Proven and inferred

- **Proven from the code:** a plain rescan keeps the running instance and
  hands it the new manifest (`shell.qml:1025-1030`). That alone is enough
  for an old `hostBinary` to meet a new version and launch an old build.
- **Not proven:** that a full `reloadPlugins()` also hands back stale code.
  It destroys services without `keepLoaded`, calls `Qt.clearComponentCache()`
  when available, and recreates them from the URL, which should read the new
  symlink target.
- **But the observed behaviour suggests stale code ran either way.** After
  the bad swap, no new instance with the 1.4.2 path swapped again, though the
  host still reported 1.4.1 for 2+ minutes.

### Consequence

The fix must not depend on which path ran. Whatever plugin code is live, a
swap must launch the build the last update installed, not a store path
compiled into that code. If stale code persists until a shell restart, the
fixed code runs only after one, so the rollout restarts the shell once on
each host.

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
  - **`installCheck`** (`:186`) uses the same rule as launching:
    `["sh", "-c", 'command -v omateams >/dev/null || test -x "$0"', hostBinary]`.
    A kept instance whose old store path was garbage-collected then still
    counts as installed when `omateams` is on `PATH`.
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

`replaceAttempted` belongs to one instance, and a full reload of **any**
plugin makes a new omateams instance with it reset. If the `PATH` omateams
were older than the manifest (say a stale `nix profile` install ahead of the
user profile), every plugin reload would swap again.

So the guard moves into the swap command and survives reloads:

- **Marker file:** `$XDG_RUNTIME_DIR/omateams/swapped-<wanted version>`.
  The swap exits at once if it exists, and creates it otherwise.
- **The swap command:**

  ```sh
  m="${XDG_RUNTIME_DIR:-/tmp}/omateams/swapped-$1"; [ -e "$m" ] && exit 0
  mkdir -p "${m%/*}" && : > "$m"
  b=$(command -v omateams) || b="$0"; "$b" quit; sleep 2; exec "$b" --hidden
  ```

  It runs with `$0` = `hostBinary` and `$1` = the wanted version.
- **Effect:** at most one swap per target version per boot, whatever the
  plugin reloads. A later version gets a new marker. `XDG_RUNTIME_DIR` is
  cleared at logout or reboot.
- **`replaceAttempted` stays,** so one instance doesn't even spawn the
  command twice.

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
- **Unit-level, in a shell, with fake `omateams` scripts** that log their
  arguments:
  - the launch snippet picks the `PATH` one, falls back to `$0` without
    it, and passes arguments with spaces through unchanged;
  - the swap snippet runs once, then exits at once on a second call with the
    same version, and runs again for a new version;
  - the install check passes with `PATH` only, with `$0` only, and fails
    with neither.
- **Runtime on p620 and razer, after the deploy and the shell restart:**
  1. **The running build.** Teams runs 1.4.3, and the exe is the user
     profile's `.omateams-wrapped`.
  2. **A swap from an older host.** Quit Teams, start the 1.4.2 store
     binary by hand, hidden, and confirm with `omateams status` that it is
     the running host. Within a status update, about 60 s, the plugin swaps
     it to 1.4.3, and `swapped-1.4.3` appears in
     `$XDG_RUNTIME_DIR/omateams/`. A shell restart before this step may have
     used up this instance's swap attempt, so check that the marker is
     absent before starting the 1.4.2 host. If it's there, delete it first.
  3. **No repeat after a reload.** Start the 1.4.2 host again, then trigger
     a full plugin reload (touch another local plugin, or rescan). The marker
     stops a second swap, and the 1.4.2 host keeps its pid.
  4. **Bar toggle.** The toggle (`command`) opens the window, and
     `coredumpctl` shows no new omateams entry.
- **What this proves, and what it doesn't.**
  - Step 2 would also pass without the `PATH` change, because after the
    shell restart `hostBinary` is already 1.4.3.
  - What proves the `PATH` change is the **next** version update, with no
    shell restart: the instance's built-in `hostBinary` is then the
    previous build, and the swap must still land on the new one.
  - The unit tests prove the selection rule now, and the README tells users
    what to expect.

## Open questions

None.
