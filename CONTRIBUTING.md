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
- **Small, focused files.** Pure logic goes in `LauncherCore` with unit tests. AppKit and SwiftUI code goes in `JevLauncher`. The background runner is `JevRunner`.
- **Local first.** Local results never wait for the network. The app makes direct requests only for the daily update check, optional Jev matching, and optional Quill through OpenRouter. HTML mail loads its web images, fonts, and style sheets unless the user turns that off. Do not add another network path.
- **Models choose or write, and never run.** Jev may return one of the candidate IDs it was given, or no match. Quill only writes text; it never picks or runs actions. Never run shell commands or text that a model produced.
- **Automations.** Agent runs use the `codex` or `claude` CLI that the user installed and signed in to. The CLI's sandbox or a fixed tool list enforces access. Read only is the default, and there is no full-access level. Never pass `--dangerously-bypass-approvals-and-sandbox`, `danger-full-access`, or `--dangerously-skip-permissions`. Other changes go through a proposal: the user approves each item, and Jevcast code applies it with a journal. Automations alert only in the notch panel, never with system banners or `osascript`.
- **Apple Events.** Use fixed script text. Values go to a script only as arguments.
- **Leave other apps alone.** Never change Spotlight, Raycast, Rectangle, or system shortcuts automatically. Keep user settings when you change a preference.
- **Privacy.** Never add file paths, clipboard text, or audio to a model request automatically. Selected text, mail, and dictation transcripts go to Quill only when the user turns on that kind in Settings › AI › Quill. Code checks each request against those switches and logs each send without its text. Never log query text.

## Before you open a pull request

1. `swift test` passes.
2. `scripts/build.sh` builds the universal app.
3. For a UI change, attach before and after images from `--snapshot-ui <dir> --demo` (see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)). Demo images contain no personal files.
4. Say which checks you did on a real Mac (keyboard focus, permissions, window moves, voice) and which you did not. Build proof and hands-on proof are different things.

Write commit messages in the [Conventional Commits](https://www.conventionalcommits.org) style, for example `fix(windows): keep the gap on the second display`.

## License

By contributing, you agree that your contribution is licensed under the [MIT License](LICENSE).
