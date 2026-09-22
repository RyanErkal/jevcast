# Development

## Layout

The package has two targets.

- `Sources/LauncherCore`: pure logic with no AppKit, so tests are fast and exact. Calculator and unit conversion, file-query parsing, search ranking, frecency, and window geometry. Tests are in `Tests/LauncherCoreTests`.
- `Sources/JevLauncher`: the app.
  - `App.swift`: app delegate, global shortcuts, open and close, snapshot runs.
  - `LauncherModel.swift`: builds, ranks, and runs results.
  - `LauncherPanel.swift`, `LauncherView.swift`, `ResultList.swift`: the panel. It is a non-activating key panel, so typing works without activating the app.
  - `FileSearch.swift`: Spotlight queries inside the configured folders.
  - `WindowManager.swift`: Accessibility window moves, snapping, and undo.
  - `SpeechService.swift`: on-device speech recognition.
  - `JevService.swift`: TypeSafe Jev selection. Validates every reply before use.
  - `UpdateService.swift`, `UpdateChecker.swift`: the daily GitHub release check.
  - `Settings*.swift`, `WelcomeWindow.swift`, `StatusMenu.swift`, `AppMenus.swift`: windows and menus.
  - `AppIdentity.swift`: name, bundle ID, and project links.

## Rename the app

Change `AppIdentity.swift` and the `APP_NAME` and `BUNDLE_ID` lines in `scripts/build.sh`. `AppIdentityTests` fails if the two disagree. Then search for the old name in `Sources`, `site`, and the documents. A new bundle ID starts with empty preferences and a new Keychain item.

## Diagnostic flags

Run the executable inside the app bundle, for example `"dist/Jevcast.app/Contents/MacOS/JevLauncher" --diagnose`.

| Flag                                       | Result                                                                                                 |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------ |
| `--diagnose`                               | Prints catalogue size, first results for sample queries, and search timings. Opens nothing.            |
| `--diagnose-files 'kind:pdf in:downloads'` | Prints file-search results from your folders for five seconds.                                         |
| `--open`                                   | Shows the launcher at launch.                                                                          |
| `--welcome`                                | Shows the welcome window at launch.                                                                    |
| `--trace-latency`                          | Prints panel and result timings. No query text.                                                        |
| `--trace-interaction`                      | Prints open, close, focus, and resize events. No query text.                                           |
| `--snapshot-ui <dir>`                      | Renders the launcher states, each Settings pane, and the welcome window to PNG files, then quits.      |
| `--snapshot-ui <dir> --demo`               | The same, with invented sample files, Apple apps only, and fresh settings. Use this for public images. |

Snapshots render the app's own views. They show layout only, not window material, shadows, or the toolbar. Snapshot windows stay transparent and never take focus, clicks, or typing.

`scripts/window-fixture.sh` opens two disposable windows for window-action checks. Avoid Tile All and Cascade All during these checks, because they move every eligible window on the display.

## Icon

`swift scripts/make-icon.swift` regenerates `Resources/AppIcon.icns` and the Icon Composer bundle `Resources/AppIcon.icon`. `scripts/build.sh` compiles the bundle with `xcrun actool`, so macOS 26 shows a Liquid Glass icon. Without actool it ships the `.icns`.

## Build notes

- `scripts/build.sh` builds arm64 and x86_64 by default. `ARCHS=arm64` builds one architecture.
- The build records the real SDK version in the binary. Without it, macOS 26 draws standard windows in the older style. The minimum system stays macOS 14.
- The bundle is assembled in `dist/.stage.*` and then moved into place, so a running copy is never changed in place.
- A local build is signed ad hoc. macOS can ask for permissions again after a rebuild.

## Website

`site/` is the landing page: static HTML, CSS, and one small script, with no build step and no third-party requests. The display font is self-hosted under the SIL Open Font License (`site/fonts/OFL.txt`).

- Preview: `python3 -m http.server 4388 --directory site`, then open `http://localhost:4388`.
- Images: the launcher states in `site/images/launcher-*.png` come from `--snapshot-ui <dir> --demo`. Replace them only with demo renders.
- Deploy: `vercel deploy site --prod`. `site/vercel.json` sets the security headers.
- The download link points to the newest GitHub release, so a release needs no website change.
