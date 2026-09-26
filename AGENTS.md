# Jevcast

Native macOS launcher and window manager. Swift Package, SwiftUI + AppKit, macOS 14+. Open source (MIT).
Use small focused files. No external dependencies. Keep local actions off network paths.

## Naming

Do not name a feature after a model. "Luna" is one OpenAI model (GPT-6 Luna), not a feature. The writing feature is "Quill". User-facing model names belong in the model picker, not feature names. Code may use model IDs for requests and capability checks. Existing storage identifiers may retain `luna` to preserve settings and keys without a migration.
Reasoning effort and Fast are separate settings. Effort is one of the model's levels (none, low, medium, high, xhigh, max). Fast is an on/off switch for the faster service tier. Never put "Fast" in an effort list.

## Network

Direct service requests are limited to the daily GitHub update check, opt-in Jev matching, and opt-in Quill through OpenRouter. Mail resource loading is the separate exception described below. Never automatically attach filesystem paths, clipboard text, or audio to model requests. Automation prompts may contain paths the user explicitly supplies or approves.
Selected text, mail content, and dictation transcripts go to Quill only when the user turns on that kind in Settings › AI › Quill. Code checks each request against those switches, and every send is logged without its text.
Automations run CLIs the user installed and signed in to (`claude`, `codex`) or commands the user wrote. Jevcast passes the approved prompt and context to those processes. The CLIs send them to their providers under the user's account. Verify subscription authentication; do not inherit an API-key billing route silently. Quill still uses opt-in OpenRouter access.

## Automations

Automations are Jevcast's own scheduler. The signed `jevcast-runner` helper in the app bundle runs them through `SMAppService`, also while the app is closed. They do not need Codex or another app.
Kinds: a script (argv the user typed or approved), an agent (a prompt run by the signed-in `codex` or `claude` CLI, Codex by default), or a script that asks an agent to diagnose only when it fails.
Agent access is enforced by the CLI, not by prompt text: Codex uses its OS sandbox (`-s read-only` or `workspace-write`, network only when the task allows it) with `--ignore-user-config --ignore-rules`; Claude uses `--restricted --safe-mode --strict-mcp-config` with a fixed tool list and never gets a command tool. Read only is the default. There is no full-access level. Never pass `--dangerously-bypass-approvals-and-sandbox`, `danger-full-access`, or `--dangerously-skip-permissions`. Remove API-key variables from agent runs so they use the subscription.
Commands an agent runs inside the CLI sandbox belong to that CLI. Jevcast itself never runs text from a model.
Changes outside the agent's access go through a proposal: JSON with operations from a fixed list, checked by code against user-set roots and recorded file identities, approved item by item, applied by Jevcast code with a journal. Deletes go to the Trash. Undo stops when a file changed; it never overwrites.
Automations stay silent. They alert only when a run needs input or approval, or fails after its retries, and only through the Jevcast notch panel. Never `osascript` or system banners for automations.
Import from Codex reads `~/.codex/automations` and never writes to it. Imported copies start paused, and one stays blocked while its Codex source is ACTIVE.
Quill tasks that read Calendar, Reminders, or Mail run in the app process, which holds those permissions.

## Safety

Do not execute shell text inferred by a model. Jev may only select known action IDs, and code validates any value it fills. Quill only writes text; it never picks or runs actions. Script tasks run only argv the user typed or approved.
Apple Events use fixed script text; values reach scripts only as arguments. Changes to mail go through Apple Mail. Mail HTML never runs scripts; it loads web images, fonts, and style sheets unless the user turns that off in the mail window (on by default, at the user's request).
Preserve user apps and settings. Do not change Spotlight, Raycast, or Rectangle shortcuts automatically.

## Checks and release

Run swift test and scripts/build.sh. Report real UI and permission testing separately from build proof.
Public images come only from --snapshot-ui <dir> --demo. Never publish captures of real files or apps.
Names and IDs live in Sources/JevLauncher/AppIdentity.swift and scripts/build.sh; AppIdentityTests keeps them in step.
Website: static files in site/, no build step, no third-party requests.
Releases: docs/RELEASING.md. Code layout and diagnostic flags: docs/DEVELOPMENT.md.
