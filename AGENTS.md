# Jevcast
Native macOS launcher and window manager. Swift Package, SwiftUI + AppKit, macOS 14+. Open source (MIT).
Use small focused files. No external dependencies. Keep local actions off network paths.
Only three features use the network: the daily GitHub update check, opt-in Jev matching, and opt-in Luna writing through OpenRouter. Never send paths, clipboard text, or audio.
Selected text, mail content, and dictation transcripts go to Luna only when the user turns on that kind in Settings › Luna. Code checks each request against those switches, and every send is logged without its text.
Run swift test and scripts/build.sh. Report real UI and permission testing separately from build proof.
Public images come only from --snapshot-ui <dir> --demo. Never publish captures of real files or apps.
Names and IDs live in Sources/JevLauncher/AppIdentity.swift and scripts/build.sh; AppIdentityTests keeps them in step.
Preserve user apps and settings. Do not change Spotlight, Raycast, or Rectangle shortcuts automatically.
Do not execute shell text inferred by a model. Jev may only select known action IDs, and code validates any value it fills. Luna only writes text; it never picks or runs actions.
Apple Events use fixed script text; values reach scripts only as arguments. Changes to mail go through Apple Mail. Mail HTML never runs scripts; it loads web images, fonts, and style sheets unless the user turns that off in the mail window (on by default, at the user's request).
Website: static files in site/, no build step, no third-party requests.
Releases: docs/RELEASING.md. Code layout and diagnostic flags: docs/DEVELOPMENT.md.
