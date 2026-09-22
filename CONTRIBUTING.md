# Contributing

Thank you for helping. Bug reports, fixes, and small focused features are welcome. For a large change, open an issue first so we can agree on the approach.

## Set up

You need Xcode 26 or later. The app runs on macOS 14 or later.

```sh
swift test                      # all tests
ARCHS=arm64 scripts/build.sh    # fast local build (scripts/build.sh builds both architectures)
open "dist/Jevcast.app"
```

[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) explains the code layout and the diagnostic flags.

## Rules the code follows

- **No third-party dependencies.** Use Apple frameworks.
- **Small, focused files.** Pure logic goes in `LauncherCore` with unit tests. AppKit and SwiftUI code goes in `JevLauncher`.
- **Local first.** Local results never wait for the network. Only two features use the network: the update check and optional natural-language matching.
- **The model only chooses.** Jev may return one of the candidate IDs it was given, or no match. Never run shell commands or text that a model produced.
- **Leave other apps alone.** Never change Spotlight, Raycast, Rectangle, or system shortcuts automatically. Keep user settings when you change a preference.
- **Privacy.** Never send file paths, folders, clipboard contents, or audio off the Mac. Never log query text.

## Before you open a pull request

1. `swift test` passes.
2. `scripts/build.sh` builds the universal app.
3. For a UI change, attach before and after images from `--snapshot-ui <dir> --demo` (see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)). Demo images contain no personal files.
4. Say which checks you did on a real Mac (keyboard focus, permissions, window moves, voice) and which you did not. Build proof and hands-on proof are different things.

Write commit messages in the [Conventional Commits](https://www.conventionalcommits.org) style, for example `fix(windows): keep the gap on the second display`.

## License

By contributing, you agree that your contribution is licensed under the [MIT License](LICENSE).
