---
status: approved
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
- **Refinement of the spec's swap snippet.** If the marker can't be
  written, the swap aborts (`|| exit 1`) instead of going ahead unguarded.
  Without this, a write failure would let every reload swap again.
- **Known limit, kept from the spec.** This rollout can't prove that the
  `PATH` lookup beats a stale `hostBinary`, because after the shell restart
  `hostBinary` is already 1.4.3. The next version update without a shell
  restart is the proof. The unit tests prove the selection rule.
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
     readonly property string swapScript: 'm="${XDG_RUNTIME_DIR:-/tmp}/omateams/swapped-$1"; [ -e "$m" ] && exit 0; { mkdir -p "${m%/*}" && : > "$m"; } || exit 1; b=$(command -v omateams) || b="$0"; "$b" quit; sleep 2; exec "$b" --hidden'
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
   - **Read the real values from `ui/Service.qml`.** Use a regex for each
     `readonly property string <name>: '<literal>'` line, then **evaluate the
     JS literal** with `Function("return " + literal)()`, so escapes are
     applied as in QML.
   - **Check the call-site wiring the same way.** Regexes assert that:
     - `hostCommand` returns `["sh", "-c", launchScript, hostBinary].concat(args)`;
     - `maybeReplaceHost` calls `["sh", "-c", swapScript, hostBinary, wanted]`;
     - `checkInstalled` uses `["sh", "-c", installedScript, hostBinary]`.

     That way `$0` and `$1` are known to be what the tests pass.
   - **Controlled `PATH`.** Make a temp directory holding:
     - symlinks to the utilities the scripts need, resolved with
       `command -v` before the test: `sh`, `mkdir`, `sleep`, and `cat`;
     - for the `PATH` case only, a fake `omateams`.

     `PATH` is that directory alone, so no real omateams can be found.
   - **Fakes.** The fake `omateams` and a fake fallback (at a path outside
     `PATH`) each append one JSON line,
     `{"who":"PATH"|"FALLBACK","argv":[...]}`, to a log file. That keeps
     argument boundaries exact; write it with `printf` in a tiny `sh` script
     using `"$@"`.
   - **Run** with
     `child_process.spawnSync(<sh path>, ["-c", script, fallback, ...args], { env: { PATH, XDG_RUNTIME_DIR } })`.
   - **Cases:**
     - **launch:**
       - with the `PATH` fake: `{who: PATH, argv: ["--hidden"]}`;
       - without it: `{who: FALLBACK, argv: ["--hidden"]}`;
       - the argument `"a b"` arrives as one argv entry.
     - **installed:**
       - exit 0 with the `PATH` fake only;
       - exit 0 with the fallback only;
       - non-zero with neither (a fallback path that doesn't exist).
     - **swap** (with `XDG_RUNTIME_DIR` set to a temp directory):
       - the first `9.9.9` call logs `quit` then `--hidden`, and creates
         `omateams/swapped-9.9.9`;
       - a second `9.9.9` call logs nothing new and exits 0;
       - a `9.9.10` call runs again;
       - with `XDG_RUNTIME_DIR` read-only (`chmod 0555`), it exits non-zero
         and logs nothing.
     - The 2 s `sleep` in the script is acceptable.
   - **Style:** the same as `tests/theme.test.js` (plain `assert`, a
     shebang, a header comment).

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
   - **Runtime checks on p620, then the same on razer**, each with the
     session environment set:
     1. **A swap from an older host.**
        - Delete any `$XDG_RUNTIME_DIR/omateams/swapped-1.4.3`.
        - Run `omateams quit`, start the 1.4.2 store binary
          (`/nix/store/bfq4g8v6…-omateams-1.4.2/bin/omateams`) with
          `--hidden`, and confirm with `omateams status` that it is version
          1.4.2.
        - Within about 60 s, the host becomes 1.4.3 (the user-profile exe),
          and the marker exists.
     2. **A fresh instance after a full reload.**
        - Run `omateams quit` (on 1.4.3), delete the marker, start 1.4.2
          hidden, and confirm it is version 1.4.2.
        - Trigger a **full** plugin reload. Touch a file in a local plugin
          the shell has loaded; it logs `Local plugin changed: <id>`, and
          because the plugin is loaded, `reloadPlugins()` runs. A rescan
          alone isn't enough.
        - With the marker gone, a swap to 1.4.3 within about 60 s proves a
          fresh instance (its `replaceAttempted` started false).
     3. **The marker holds across a reload.**
        - Run `omateams quit` (on 1.4.3), keep the marker, start 1.4.2
          hidden, and trigger the same full reload.
        - The 1.4.2 host is **not** swapped and keeps its pid for 2
          minutes.
        - Then `omateams quit && omateams --hidden` back onto 1.4.3.
     4. **The bar.** The toggle opens the window, and `coredumpctl` shows
        no new omateams entry.
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
