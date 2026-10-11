<!-- Moved out of README.md; the README links here. -->
## Primary interfaces

### Workspace discovery

The viewer tries, in order:

1. the path saved under `probierzDesktop.workspaceRoot`;
2. `WISENT_WORKSPACE_ROOT`;
3. current directory;
4. `~/Documents/CodingProjects/Wisent`;
5. bounded ancestors of the application bundle.

A valid workspace contains regular, non-symlink files at:

- `probierz/package.json`;
- `probierz/agent/history.mjs`.

### Project adoption and the incident register

Probierz Desktop keeps no Probierz process running. Each operation is one
finite call to the Probierz CLI for the selected repository, and the window
reads the JSON that command prints:

- adoption runs `probierz --harness <repository> project adopt --source <path> [--replace]`;
  a conflict is shown from the result the command prints before it exits 1;
- retained source identities come from `probierz project adoptions`;
- the register runs `probierz incident list|show|record|resolve --json`, with
  the envelope written to `record --envelope -` on stdin.

A refusal shows the `detail` of the `probierz-failure` line the CLI writes to
stderr, the same sentence an operator sees. The binary is `PROBIERZ_BIN`, then
this checkout's `probierz-rs/target/{release,debug}/probierz`, then
`~/.local/bin/probierz`. Both the GUI and the CLI therefore call the same core
transactions rather than maintaining separate parsers or copying files in
Swift.

### Contract inventory

| Contract | Relative path |
|---|---|
| Node package | `probierz/package.json` |
| Las MCP surface | `probierz/agent/mcp.mjs` |
| history boundary | `probierz/agent/history.mjs` |
| application surfaces | `probierz/apps/` |
| result store | `probierz/test-results/` |
| shared configuration | `probierz/tsconfig.base.json` |

### Configuration presence

The viewer reports presence—not values—for Android SDK, iOS app/device/version,
Appium, browser path, artifact-encryption key file, color scheme, locale, release,
bundle ID, and workspace-root variables used by local Probierz surfaces.

### Reported failures

Failures reads every `*.jsonl` file in the failure intake directory
(`PROBIERZ_FAILURES_DIR`, else `~/.probierz/failures`). A missing directory is
nothing reported. A directory that cannot be inspected or listed, and a
service's file that cannot be read, are listed in a danger panel
**Some reported failures cannot be read** as `path: cause`, and the screen does
not claim that nothing has reported while one is unreadable.

### First-use walkthrough

A step that returns no next screen displays the current screen identifier and
states that progress did not advance. A successful replay clears the previous
walkthrough error only after reset, screen synchronization and event flush
complete; a failed replay remains a failure rather than displaying success.

The source-owned `tests/onboarding/FirstUseJourneyTests.swift` journey uses the
real native controller, storage and configured Stado transport. On the dedicated
qualification host, declare `PROBIERZ_TEST_WORKSPACE` as an actual retained
Probierz workspace, `PROBIERZ_TEST_PROTECTED_ARTIFACT_ID` as its available
protected bundle's native identity and `PROBIERZ_TEST_SOURCE_REVISION` as the
exact revision of the matching test bundle. Retain the release evidence binding
that revision to the bundle, plus the command, exit status and XCTest output.

Run the already-built target with
`swift test --skip-build --filter FirstUseJourneyTests`.
It rejects an inspection before the terminal screen, completes after reaching
that screen, reads completion through a new controller, replays, and checks that
the new entry step remains incomplete after the earlier artifact is observed.
Only its isolated UserDefaults suite is removed; retained run evidence and
operator defaults are unchanged. Missing real artifacts or transport failures
fail the journey. This native-client integration does not replace graphical
verification of the first-use screens, refusal messages or recording.

### Run manifest projection

A manifest may contribute:

- run, application, target, and kind labels;
- status and start/completion timestamps;
- duration;
- artifact relative path, declared bytes, optional SHA-256, and local file
  metadata.

Identifiers longer than 160 characters, empty values, control characters,
unsafe artifact paths, symlinks, and out-of-root paths are rejected or replaced
with an explicit fallback.

