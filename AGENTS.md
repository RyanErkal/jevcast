# Jevcast
Native macOS launcher and window manager. Swift Package, SwiftUI + AppKit, macOS 14+. Open source (MIT).
Use small focused files. No external dependencies. Keep local actions off network paths.
Only two features use the network: the daily GitHub update check and opt-in Jev matching. Never send paths, clipboard text, or audio.
Run swift test and scripts/build.sh. Report real UI and permission testing separately from build proof.
Public images come only from --snapshot-ui <dir> --demo. Never publish captures of real files or apps.
Names and IDs live in Sources/JevLauncher/AppIdentity.swift and scripts/build.sh; AppIdentityTests keeps them in step.
Preserve user apps and settings. Do not change Spotlight, Raycast, or Rectangle shortcuts automatically.
Do not execute shell text inferred by a model. Jev may only select known action IDs.
Website: static files in site/, no build step, no third-party requests.
Releases: docs/RELEASING.md. Code layout and diagnostic flags: docs/DEVELOPMENT.md.
