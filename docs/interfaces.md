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

