# ForkSync

[Deutsch](README.de.md) · **English**

A Mac app that keeps your GitHub forks up to date – without losing your own commits.

- **Automatic**: a fork without own commits is mirrored (fast-forward). With own commits, upstream is merged in; on conflicts a pull request is opened instead.
- **Detects fake "own" commits** (bots, the original author's commits after upstream rewrote its history).
- **Schedule via dropdown** (hourly to weekly), runs as a GitHub Action inside each fork.
- **Sync now** with one click, even when upstream changes workflow files.
- **Sign in with GitHub** (device flow); the token is stored in the macOS keychain. An existing `gh` login is used as a fallback.
- **Change repo visibility** (public/private) with prominent warnings.
- **German and English interface**, switchable in the toolbar.

## Installation

Download the DMG from [Releases](../../releases), drag `ForkSync` to your Applications folder, launch it and click "Sign in". The app is signed with a Developer ID and notarized (macOS 14+).

## Build from source

```
./build_app.sh --install   # builds and installs to /Applications
./build_app.sh --release   # notarizes and builds build/ForkSync.dmg (requires your own Apple credentials)
```

A command-line version, `forksync.py`, is also included (Python 3.9+, standard library only, requires `gh`).

## License

[PolyForm Noncommercial 1.0.0](LICENSE): you may use, view, fork and modify ForkSync for **noncommercial** purposes. **Commercial use** (e.g. selling it, or building it into a paid product or service) is **not permitted**. This is therefore not an OSI open-source license but "source-available". Please contact the author first for commercial use.

## Disclaimer

Use at your own risk. The software is provided "as is", without warranty of any kind. To the extent permitted by law, the author accepts **no liability** for damages of any kind, in particular for data loss, modified, overwritten or deleted commits, branches, pull requests or workflows, failed syncs, or accidentally published or exposed data (for example by switching a repository to "public"). Review changes before running them and back up important repositories.

## Privacy

The app only talks to the GitHub API. There is no telemetry. The workflow inside a fork uses the `GITHUB_TOKEN` provided by GitHub; no secrets are stored.
