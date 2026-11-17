---
status: draft
issue: none (issues are disabled on this repo)
spec: spec/2026-11-17-host-swap-stale-binary.md
coders:
  1: codex   # small, tricky shell-in-QML quoting and the swap guard
  2: coder   # a node test that drives the three scripts with fake omateams binaries
  3: coder   # version bump and a README paragraph
reviewers:
  - codex    # independent read of the diff against this plan, beside the Opus review
---

# Plan: Swap a hidden Teams window onto the build that was just installed

## Approved decisions (from the spec)

- **The cause.**
  - Proven: the shell can keep a running plugin instance and hand it a new
    manifest (omarchy-edge `shell.qml:1025-1030`). That instance's built-in
    `hostBinary` names an older build.
  - Not proven: that a full reload also hands back stale code.
  - So the fix doesn't rely on which plugin code is live.
- **Launch through `PATH`.** Every host launch in `ui/Service.qml` runs
  `omateams` from `PATH`, falling back to `hostBinary`, via
  `sh -c '…' hostBinary args…`, where `$0` is `hostBinary`.
- **Swap guard that survives reloads.** The marker
  `$XDG_RUNTIME_DIR/omateams/swapped-<wanted version>` allows one swap per
  version per boot, across plugin reloads. `replaceAttempted` stays.
- **`installCheck` follows the same rule:**
  `command -v omateams >/dev/null || test -x "$0"`.
- **Unchanged:** when a swap happens, and every line `nix/package.nix`
  substitutes. That is the `hostBinary` property line, `Component.onCompleted:
  ensureHost()`, and `if (!installed) { ensureHost(); return }`; they must
  stay byte-identical, or the package's `--replace-fail` breaks the build.
- **Version 1.4.3** and a README "Updating" note.
- **Rollout, owner pre-approved ("deploy when ready"):**
  1. PR, then merge.
  2. A lock bump PR in nixos_config, then merge.
  3. Deploy p620 and razer from `main`, after checking the agent bus.
  4. Restart the shell once per host, then restart omateams.
  5. Run the runtime checks.
- **Scope:** version changes only.

## Repo traps (apply to every step)

- `nix/package.nix` uses `substituteInPlace --replace-fail` on exact
  `Service.qml` lines (see above). Don't reformat those lines.
- Shell scripts inside QML string literals: use single-quoted JS strings for
  the `sh` script, as `maybeReplaceHost()` does today, so `$` and `"` stay
  literal.
- QML style in this file: `function`, `var`, short why-comments in plain
  English.
- Line numbers are from commit `06f03e5`. Re-find them with `grep`.
- Implementers don't stage, commit, build or deploy.

## Steps

1. **`ui/Service.qml`: launch by command name, with a guard that survives
   reloads.**
   - **Add three read-only string properties** next to `hostBinary`
     (`:26`), with this comment:

     ```qml
     // The plugin's code can outlive several updates in a running shell, so the
     // store path baked into hostBinary may be an old build. These run the
     // omateams on PATH (what the last update installed) and fall back to
     // hostBinary, passed as $0.
     readonly property string launchScript: 'b=$(command -v omateams) || b="$0"; exec "$b" "$@"'
     readonly property string installedScript: 'command -v omateams >/dev/null || test -x "$0"'
     // One swap per target version per boot, even across plugin reloads ($1 = version).
     readonly property string swapScript: 'm="${XDG_RUNTIME_DIR:-/tmp}/omateams/swapped-$1"; [ -e "$m" ] && exit 0; mkdir -p "${m%/*}" && : > "$m"; b=$(command -v omateams) || b="$0"; "$b" quit; sleep 2; exec "$b" --hidden'
     ```

   - **Add a helper:**

     ```qml
     function hostCommand(args) { return ["sh", "-c", launchScript, hostBinary].concat(args) }
     ```

   - **Use it at every launch:**

     | Where | Becomes |
     |---|---|
     | `maybeAutostart()` (`:93`) | `Quickshell.execDetached(hostCommand(["--hidden"]))` |
     | `command()` (`:107`) | `Quickshell.execDetached(hostCommand([name]))` |
     | `maybeReplaceHost()` (`:174`) | `Quickshell.execDetached(["sh", "-c", swapScript, hostBinary, wanted])` |
     | `checkInstalled()` (`:186`) | `installCheck.command = ["sh", "-c", installedScript, hostBinary]` |

   - **Update the comment above `maybeReplaceHost()`** (`:165-168`) with
     one sentence: the swap launches the `PATH` omateams, and the marker
     stops a repeat after a reload.

   Verify:

   ```bash
   grep -n 'execDetached(\[hostBinary' ui/Service.qml
   grep -c 'hostCommand(\|swapScript\|installedScript' ui/Service.qml
   ```

   - The first grep must print nothing, and the second must count at least 6.
   - Run the `qmllint` from the plan's Tests section on `ui/Service.qml`.
     Expect no new warnings against `master` (compare the outputs).
   - The three substituted lines are unchanged:

     ```bash
     git diff master -- ui/Service.qml | grep -E '^[-+].*(hostBinary: |Component.onCompleted: ensureHost|if \(!installed\) \{ ensureHost)'
     ```

     That diff must show no such line.

2. **`tests/launch.test.js`: unit tests for the three scripts.**
   - **Read the scripts from `ui/Service.qml`.** A regex extracts each
     `readonly property string <name>: '<script>'` value.
   - **Run them** with `child_process.spawnSync("sh", ["-c", script, fallback, ...args], { env })`.
   - **Fixtures** live in a temp directory, using `fs.mkdtempSync`:
     - a fake `omateams` on a temp `PATH` directory, which appends
       `PATH:` plus its argv to a log file;
     - a fake fallback at another path, which appends `FALLBACK:` plus its
       argv.
   - **Cases:**
     - **launch:**
       - with the `PATH` fake, it logs `PATH: --hidden`;
       - with `PATH` holding only the system dirs (`/run/current-system/sw/bin`
         or `/usr/bin`) and no fake, it logs `FALLBACK: --hidden`;
       - an argument with spaces arrives as one argument.
     - **installed:**
       - exit 0 with the `PATH` fake only;
       - exit 0 with the fallback only (it exists and is executable);
       - non-zero with neither (the fallback path doesn't exist).
     - **swap** (with `XDG_RUNTIME_DIR` set to a temp directory, and the
       fake ignoring `quit`):
       - the first call with version `9.9.9` logs `quit` and then
         `--hidden`, and creates `swapped-9.9.9`;
       - a second call with `9.9.9` logs nothing new;
       - a call with `9.9.10` runs again.
       - The fake must not sleep; the 2 s `sleep` in the script is
         acceptable.
   - **Style:** the same as `tests/theme.test.js` (plain `assert`, a shebang,
     a header comment).

   Verify: `node --test tests/launch.test.js` passes.

3. **`manifest.json` and `README.md`.**
   - `manifest.json`: `"version": "1.4.3"`.
   - **README "Updating"** (`:179-192`): replace the paragraph after the
     first code block with three points:
     - after an update that changes the version, a hidden window moves to
       the new build by itself, once per version;
     - after the first update to 1.4.3, restart the shell once, or log out
       and in, so the fixed plugin code is the one running;
     - a rebuild that keeps the same version still needs the manual
       restart.

     Keep the existing `omateams quit && omateams --hidden` block for that
     last case.

   Verify: read it back. `grep '"version"' manifest.json` prints `1.4.3`.

4. **Lead: check, review, release.**
   - Run every check in the Tests section.
   - Run the Opus review (a fresh agent given only this plan and `git diff`)
     and the Codex review. Fix confirmed findings, then commit, naming the
     steps.
   - Open the PR linking all three artifacts, then merge it.

5. **Lead: deploy** (pre-approved).
   - In nixos_config, use a clean worktree off `origin/main`.
     `nix flake update omateams`, check that both hosts evaluate to 1.4.3,
     then open a PR and merge it once CI is green.
   - Pull it into `~/.config/nixos`, keeping any uncommitted work the owner
     has there.
     - `nix store diff-closures` of each host's current system against the
       new build must show only omateams 1.4.2 → 1.4.3.
     - Anything else means the deploy differs from what is running; stop
       and ask.
   - Read the agent bus and post a hold notice. Then
     `AGENT_BUS_ANNOUNCED=1 just deploy` on p620, and
     `AGENT_BUS_ANNOUNCED=1 just deploy-local-build razer`.
   - **On each host:**
     1. Restart the Omarchy shell once; announce it on the bus first.
     2. `omateams quit && omateams --hidden`.
     3. Check that the exe is the 1.4.3 user-profile `.omateams-wrapped`.
   - **Runtime checks 2-4** (spec Verification) on p620:
     1. Delete any `$XDG_RUNTIME_DIR/omateams/swapped-1.4.3`.
     2. `omateams quit`, then start the 1.4.2 store binary hidden, and
        confirm it is the running host.
     3. Within about 60 s it is swapped to 1.4.3, and the marker exists.
     4. Start 1.4.2 again, then trigger a full plugin reload: edit and
        revert a file in a local plugin, or `omarchy-shell shell
        rescanPlugins`. It is **not** swapped again, and keeps its pid.
     5. Restart onto 1.4.3.
     6. Check the bar toggle, and that `coredumpctl` shows no new entry.
   - **On razer:** the running exe is 1.4.3, and swap check 3 above
     passes.
   - Post done on the bus, and record the results in the PR.

## Tests

```bash
/nix/store/0jnxd2cwya279hyr7hmklbpdb0298lg1-qtdeclarative-6.12.0/bin/qmllint ui/Service.qml   # no new warnings vs master
node --test tests/launch.test.js                                                               # passes
nix flake check                                                                                # passes (package builds; --replace-fail lines intact)
grep -n 'execDetached(\[hostBinary' ui/Service.qml                                             # nothing
```

`node --test tests/` as a whole still fails here, because the theme test
needs `/usr/share/omarchy/themes`. That failure is pre-existing and not
caused by this change.

## Rollback

- **Code:** revert the merge commits in this repo and nixos_config, then
  redeploy. Restart the shell to unload the fixed plugin code.
- **Marker files:** they live in `$XDG_RUNTIME_DIR` and go at logout.
