# Probierz Desktop

Probierz Desktop is the native macOS viewer for local Probierz contracts, configurations, run history, and evidence artifacts.

## Scope

The application:

- locates or lets the operator choose a local Wisent workspace;
- reads Probierz contract and configuration metadata;
- displays local run history and artifact metadata;
- filters runs by query and status;
- keeps workspace selection in local user defaults;
- authenticates through the shared `wisent-desktop-auth` package where a Wisent service is used.

It is an inspection client. It does not execute tests, decide a quality gate, upload evidence, or make a local result trustworthy by itself. Probierz core owns execution, evidence, receipts, and gate evaluation.

## Build from source

Requirements:

- macOS supported by `Package.swift`;
- a compatible Swift toolchain;
- access to the public `wisent-ai/wisent-desktop-auth` package.

```sh
git clone https://github.com/wisent-ai/probierz-desktop.git
cd probierz-desktop
swift build
```

No stable signed binary channel is currently promised. Published source and a future signed application release are separate support commitments.

## Support and security

- Source and issues: [`wisent-ai/probierz-desktop`](https://github.com/wisent-ai/probierz-desktop)
- Vulnerabilities: [private GitHub Security Advisory](https://github.com/wisent-ai/probierz-desktop/security/advisories/new)
- License: Apache License 2.0; see [`LICENSE`](LICENSE)
