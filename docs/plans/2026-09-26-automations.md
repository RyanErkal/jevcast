# Automations, AI naming, and notch alerts: plan

Status: approved 2026-09-26, in build. Decisions: the writing feature is "Quill"; Codex is the default runner, Claude is also offered; the runner needs an Apple Development or Developer ID signed build; agent access has three levels (read only, edit its folder, edit its folder and use the network) enforced by the CLI sandbox or tool list; a later drafts/reports schema is wanted. Date: 2026-09-26.

## Goals

1. One place in Jevcast to create, run, watch, and approve background work.
2. Agent runs use Ryan's signed-in ChatGPT or Claude subscription through the local `codex` and `claude` CLIs. Verify the account and billing route during setup. The separate Writing runner uses OpenRouter credits and a key.
3. Schedules work after Jevcast quits and after restart and login. They do not need the Codex desktop app. A user LaunchAgent does not run while logged out or powered off. Sleep delays work. Interrupted processes do not survive restart.
4. Human-in-the-loop: an agent proposes changes, Ryan approves each item, and Jevcast code applies them with a recovery journal. Undo is conditional on the files still being available and unchanged.
5. Silent by default. Show input, approval, and final failure alerts in a panel below the MacBook notch.
6. Read and port the Codex automations, including the Stein, Robert Parish, and ReDesign metrics jobs. A port must preserve its workflow, not just its schedule.
7. Rename the writing feature to "Quill". Keep the model name in the picker. Split Fast from reasoning effort.

Non-goals: a cloud runner, running on another Mac, changing the Codex automation registry, and model-written shell commands. CLI authentication and session persistence may write their own files in `~/.codex` or Claude's data folder. The importer never writes there.

## Current state (verified 2026-09-26)

- Scheduled view: lists launchd jobs, crontab, Jevcast timers, and Luna tasks. `ScheduledSource.swift` offers Run Now and Turn On/Off for agents, timer cancellation, and task controls. It is not read-only. `LauncherCore/ScheduledJobs.swift` parses schedules; it is not a runner.
- Luna Tasks: an in-process 30 s loop with a wake check. It runs while the app process lives, even with its window hidden. It uses OpenRouter, reads permitted Calendar, Reminders, and unread mail context, and writes Markdown under `Jevcast/Luna Tasks`. Late runs are skipped. Its notifications use `UNUserNotificationCenter` (`LunaTaskCenter.swift`). A failed result-file write can still record success with no file. The new runner must require durable output before success.
- `LunaEffort` exposes Fast, High, Max in Settings and has an internal `off = "none"` case. Fast sends reasoning `low`. `LunaRequest.model` is fixed to `openai/gpt-6-luna`. `LunaService.swift` sends no speed tier.
- `Notifier.swift` also supplies system notifications for timers and command output. Changing task alerts must not break those existing callers.
- `Package.swift` has one executable product, `JevLauncher`. `scripts/build.sh` packages only that executable. It uses Apple Development signing when available, otherwise ad-hoc signing. It does not package or register a runner. `App.swift` runs an accessory app and has no automation alert launch mode.
- Codex registry: nine version 1 heartbeat files, six ACTIVE and three PAUSED. Each has an RRULE and target thread. Active: daily-docs-backup, global-thread-lifecycle, john-trudel-weekly-meta-ads-report, redesign-daily-metrics, robert-parish-daily-metrics, stein-firm-daily-metrics. Paused: basu-end-to-end-growth-report, daily-mva-outreach, goodrich-weekly-meta-ads-report.
- Models and efforts are prose in the prompts. No file supplies a structured timezone or cwd. Only Stein and ReDesign supply `notification_policy`. John Trudel checks daily at 04:20 despite its weekly name. Metrics jobs run every four hours.
- The installed watchdog plist calls `automation_health.py --notify` every 1800 s. Its `mac_notifier` invokes `osascript display notification`. This is a verified possible source of generic script banners, not proof of the source of every banner. The plist's presence does not prove it is loaded. Health state is a dated external assessment, not runner state.
- Stein and ReDesign sidecars are schema version 4. Robert Parish is version 5. Shared top-level fields do not imply identical KPI meanings. ReDesign is outside the clients glob, under `2-marketing/paid-ads/meta-ads/redesign-pi-firm-ads/`.
- CLI help was read without starting a run. Claude supports print, stream-json, schema, resume, `--tools`, `--allowedTools`, `--restricted`, `--safe-mode`, and `--permission-prompts none`. Its effort values are low, medium, high, xhigh, max. Its permission modes do not include `default`. No Fast flag is listed. Codex exec supports JSON, schemas, sandbox, `--ignore-user-config`, and `--ignore-rules`. Resume has its own option set and does not list `-s` or `-C`. Help does not prove effective isolation or service-tier values.

## Part A: Rename and settings (small, ships first)

### A1. Naming

- User-facing: "Luna" becomes "Quill". Settings › AI tabs: Jev, Writing, Automations, Usage.
- Code: `Luna*` types become `Writing*`. Move `LunaTask*` into Automations only when Part B is ready. Rename prompts, errors, search labels, help, and dictation copy. Remove model-branded command aliases. Keep `ask` and `?`.
- System prompt: "You are the writing helper inside Jevcast".
- Add a model picker with `openai/gpt-6-luna` as the initial value. Show only verified models and capabilities. Do not substitute a model silently.
- Keep the bundle ID, existing UserDefaults key strings, and Keychain service/account identifiers as canonical storage identifiers. This rename does not require a data migration or a second read path. Rename Swift symbols only. Include `lunaActivity`, privacy switches, and the shared Jev OpenRouter key path in regression checks. An unreadable Keychain item is not an absent key.
- Preserve stored effort raw values until an explicit settings conversion is needed. Keep the raw value `fast` as the identifier for Low, not as a second effort choice. Internal `none` remains available for dictation.
- Update the site, `docs/DEVELOPMENT.md`, Help source, and demo UI snapshots during implementation. This review edits only this plan and AGENTS.md.

### A2. Effort and Fast

- `ReasoningEffort`: none, low, medium, high, xhigh, max. Use a capability table keyed by provider, model, and CLI version. Show only verified values. Unknown capability blocks the unsupported setting; never default to all levels.
- `fast: Bool`, off by default, is a separate setting. Show provider-specific quota or credit text only when verified. Do not call an effort or routing preference Fast.
- OpenRouter: effort currently maps to `reasoning.effort`. Throughput routing is not proof of a priority service tier. Phase 0 must verify supported priority semantics, request fields, and returned evidence for the selected model. Hide Fast until proved.
- Codex: phase 0 must verify `model_reasoning_effort` and accepted `service_tier` values and their effect. Do not assume `fast|standard`. The local config says `service_tier = "default"`; a config value is not proof of provider behavior.
- Claude: use verified `--effort` levels supported by the selected model. No Fast flag was found in the installed help. Hide Fast unless a supported noninteractive interface is proved.
- Existing Fast effort displays as Low with Fast off. High and Max retain their meaning. New settings must not turn on any data-send switch.

## Part B: Automations

### B1. Concepts

- **Automation**: a named task with a schedule, kind, and policies. Store one versioned JSON definition per automation in `~/Library/Application Support/Jevcast/Automations/<id>/automation.json`. Store runs in `runs/<run-id>/` with `run.json`, output, and optional proposal and journal.
- Generate IDs in code. Validate IDs before path construction. Use owner-only directories (0700) and files (0600). Reject symlinks, unexpected owners, and unsupported formats at state boundaries. Same-user file permissions do not isolate a malicious child process. The child must not be able to alter definitions, approvals, journals, or request queues.
- **Kinds**:
  1. `script`: approved executable, argv, cwd, and environment. No shell unless Ryan supplies it explicitly. Approval binds the script content, interpreter, and working directory. Changes require review. Scripts are trusted code, not read-only agents; show their local and external effects.
  2. `agent`: a prompt sent through `codex`, `claude`, or `writing`. Agents produce text or proposals. They cannot apply changes.
  3. `script` + `onFailure: agent`: deterministic collection followed by a bounded diagnostic report on failure. Send only approved, redacted error context. Some ports also need explicit steps after success (B9).
- **Output mode**: `report`, `proposal`, or `ask`. Use a versioned envelope with a discriminator for structured responses. Parse and validate in Jevcast even when the provider accepts a schema. Markdown is inert text, not executable HTML.
- **Policies**: default timeout 20 min; overlap skip; catch-up skip or runOnce; quiet hours; alerts for needsInput, needsApproval, and final failure. Successful reports remain in history without a banner. Remove `always` from the alert policy.
- Retry only classified transient failures when safe. Scripts default to no runner retry, since the metrics scripts already retry reads. Never repeat a possibly applied side effect automatically. Auth, validation, policy, and permission failures need input. A timeout is not proof that no work occurred.
- State machine: queued, running, retryWaiting, needsInput, needsApproval, applying, succeeded, failed, cancelled, interrupted, rejected, expired. Persist each transition and its revision. A run waiting for input holds no CLI process. Default: block the next run of that automation until resolved.

### B2. Schedule

- Implement a bounded RRULE subset: `FREQ=HOURLY|DAILY|WEEKLY`, positive `INTERVAL`, `BYDAY`, `BYHOUR`, `BYMINUTE`; plus `once(date)`. Accept the observed `RRULE:` prefix. Reject unsupported or invalid fields instead of dropping them.
- Store an explicit start anchor, IANA timezone, and schedule revision. RRULE alone cannot preserve Codex's hourly phase or timezone. Import requires a confirmed first occurrence and timezone. Show the next several occurrences before enablement.
- Define DST behavior: skip nonexistent local times and run once at the first occurrence of repeated local times. Hourly intervals use elapsed time from the anchor. Persist occurrence IDs so backward clock changes do not repeat work. Skip consumes missed occurrences; runOnce consumes the backlog and queues one run. Neither creates an unbounded catch-up loop.
- The UI offers presets and the existing `LunaTaskQuery` parser's supported forms. Do not promise arbitrary natural language. A schedule edit or re-enable starts a new confirmed schedule revision.

### B3. Runner process

- Add a separate SwiftPM executable target using LauncherCore. Proposed bundle path: `Jevcast.app/Contents/MacOS/jevcast-runner`. Package both architectures and sign nested code before signing the outer bundle. No helper exists today.
- Proposed registration: `SMAppService.agent(plistName:)`, with the plist under `Contents/Library/LaunchAgents` and a bundle-relative executable reference. Use the logged-in user's GUI session, not a root daemon. Phase 0 must prove the exact plist keys, installed location, registration, and lifecycle on macOS 14+.
- Test unsigned, ad-hoc, Apple Development, and Developer ID bundles where available. Do not promise SMAppService support or a specific Login Items icon/name for untested signing modes. If the shipped signing mode cannot register, block this feature and state the requirement. Do not silently install a second launchd path.
- Use one long-lived scheduler with an internal timer and wake check. Phase 0 verifies its launchd keep-alive and restart settings. `StartInterval` does not launch another instance while the job is running and cannot serve as its internal timer. Launchd is not an exact-time or wake-from-sleep service.
- The helper owns run state and claims. UI actions, including Run Now, become durable requests. A process-wide lock prevents duplicate helpers. Claim each occurrence and persist the immutable definition revision before spawning. Keep lock descriptors open; never unlink a live lock file. Use shared resource locks for jobs that touch the same repository or metrics store.
- Bound global concurrency (initially two children) and serialize runs per automation. Drain stdout and stderr concurrently with byte and duration limits. Set stdin explicitly. On timeout or cancellation terminate the process group, escalate after a grace period, and reap it. Prove descendant cleanup in phase 0.
- Recover queued and running records after a crash. Distinguish failed spawn, active owned child, and uncertain completion. PIDs alone are not identity. Do not retry interrupted scripts until reconciled. Exactly-once external effects cannot be guaranteed by a lock and atomic JSON. Preserve script receipts and idempotency keys.
- Use revision checks, atomic replacement, and durable journal writes. Startup reconciles incomplete transitions. Define Pause as stopping future runs and Cancel as a separate action for current work. App upgrades stop admission, drain or cancel work, and restart the matching helper before accepting a new state format.
- Resolve executables during setup from known paths or a user selection. Do not run `zsh -lc` merely to discover PATH; shell startup files execute code. Store a reviewed PATH and minimal environment. Check executable identity on launch and request review after a change.
- Remove inherited API-key and provider override variables from subscription tasks. Do not expose script secrets to diagnostic agents. Read Keychain items without background prompts; denied access becomes needsInput. Verify helper access separately.
- Sleep and restart invoke catch-up after wake or login. Optional activity assertions may reduce idle sleep; they do not override lid closure or power loss.
- Durable files carry requests and state. Darwin notifications are unauthenticated, lossy wake hints with no payload. Always rescan on startup and periodically. Validate request IDs, revisions, size, ownership, and replay status. They never authorize an operation. The app owns approval and apply records; the CLI cannot write those locations.

### B4. Runner commands (fixed argv, built by code)

- Candidate Codex invocation: `codex exec --ignore-user-config --ignore-rules --skip-git-repo-check --json -s read-only -m <model> -C <approved-cwd> --output-schema <schema> -`. Send the prompt on stdin. Add only verified configuration overrides. The local config currently requests full access, so inherited config is unsafe.
- `-s read-only` constrains model shell commands; it does not disable them, confine reads to allowedRoots, or prove that hooks and MCP tools cannot write. The product forbids model-written commands. Phase 0 must prove a supported way to disable command execution, hooks, plugins, external tools, and unapproved file reads while retaining subscription auth. If it cannot, the Codex agent runner is blocked. Do not relax the policy to ship it.
- Candidate Claude invocation: `claude -p --output-format stream-json --verbose --restricted --safe-mode --strict-mcp-config --mcp-config <empty-config> --tools <fixed-read-tools> --allowedTools <same-tools> --permission-mode plan --permission-prompts none --json-schema <schema>`. Supply the prompt through stdin and set cwd directly. Verify this combination in phase 0. `--allowedTools` alone is not a sandbox. No Bash, write tools, network tools, agents, or arbitrary MCP tools.
- Prefer a private run workspace containing only user-approved context snapshots. Never copy executable project settings, hooks, or instructions into it. Verify filesystem confinement and protection of the real home and control state. CLI read-only mode alone does not give that guarantee.
- Workspace-write agent access is a per-task choice with a warning, confined to the working folder and allowed roots by the Codex sandbox or the Claude tool list and `--restricted`. Changes outside that go through B5. No bypass flags or full access.
- File contents, logs, imported prompts, and model replies are untrusted data. A fixed header explains that boundary but cannot enforce it. Restrict tools and reads, bound context, keep secrets out, and validate outputs. Test prompt injection that asks to run commands, expose files, change roots, or approve its own proposal.
- Resume only a validated session ID created for this Jevcast run. Reapply and verify all isolation, model, cwd, and schema settings on every round. Codex resume has different flags; phase 0 must prove the effective policy. Block resume if it cannot retain the same limits. Never use `--last` or resume the imported Codex target thread.
- Parse bounded JSON events, terminal result, exit status, and structured errors. Exit 0 alone does not prove task success. Usage can be missing or cumulative; display Unknown when absent and avoid double-counting resumed turns. Tokens are not a subscription balance or a bill.
- Persist final output through the runner. Raw streams can contain private content and secrets. Do not save them by default. Allow bounded diagnostic capture only with explicit opt-in, redaction, retention, and delete controls. CLI-owned session storage has its own retention and must be disclosed.

### B5. Proposals (human in the loop)

- The agent returns a versioned schema with summary and items. Each item has a unique ID, fixed op, typed args, and reason. Schema validation rejects extra fields, unknown ops, invalid strings, duplicates, and oversized output. Maximum 500 items plus a byte limit.
- Allowed ops (v1): `move(from, to)`, `rename(path, name)`, `mkdir(path)`, `trash(path)`, `tag(path, tags)`. Defer `open_url` and `run_script`: an HTTPS URL can leak data or trigger server actions; a saved script ID can grant broad authority. Users can start scripts separately after reviewing their full definition.
- `allowedRoots` come only from user configuration. Never from a prompt or proposal. Apply component-wise path containment, not string prefixes. Reject traversal, NULs, symlink components, special files, root operations, protected state/config paths, and overlapping or cyclic items. Rename names must be one valid component. Reject hard-linked file mutations in v1.
- Existing sources and destination parents must be inspected through trusted filesystem code. For a missing destination, validate the existing parent and the new leaf. Reject overwrite. Do not choose an unseen auto-suffix after approval. A collision needs a new preview.
- Code records a trusted manifest before showing the proposal: root and parent identities, device/inode, file type, size, timestamps, relevant metadata, and content digest where needed. Never trust model-supplied size or modification dates. Bind approval to the manifest, proposal digest, task revision, exact destinations, and selected item IDs.
- Approval window: inert text, from and to paths, reasons, item checkboxes, Approve selected, Reject all, and Ask agent to revise. Revisions invalidate all prior approvals. Load previews only for validated local files and only on demand. Never render active remote content from the proposal.
- Apply in Jevcast's authorized app process through a single serialized executor. Revalidate at apply and undo. Phase 0 must prove race-resistant descriptor-relative traversal, no-follow opens, no-overwrite operations, and identity checks on macOS. Path checks followed by `FileManager.moveItem` are not a TOCTOU solution. Fail closed for operations that cannot meet the proof.
- Limit v1 moves to one volume. Directory moves need a bounded manifest of their contents or must be rejected. External writers can change files; do not promise an atomic batch. Reject dependent selections and stop at the first conflict. Report applied, skipped, and uncertain items separately.
- Journal durable intent before each operation and observed outcome after it. On crash, reconcile before any retry. A filesystem operation and a journal write are not one transaction.
- Undo verifies that applied objects are unchanged and original destinations are vacant. Store previous tags. Remove a created directory only if still empty. Restore Trash items only from a verified recorded Trash location with no overwrite. Trash may be cleared, unavailable, or on another volume. A blocked undo needs recovery instructions, never a permanent-delete fallback. Trash race handling is a phase 0 gate.
- Proposals expire after seven days. Expiry, task edits, or permission changes invalidate unapplied approvals. Expiry does not erase recovery journals.

### B6. Ask mode (input needed)

- A valid question envelope ends the CLI process and persists needsInput. Show a short alert; open an input window when Ryan clicks Answer. Keyboard input requires an explicit focus change.
- Persist the answer and round ID before queueing resume. Repeated clicks must not create two rounds. Up to three rounds per run. Set an input expiry and support Cancel. Losing a session becomes needsInput with a clear recovery choice, not an automatic fresh run.
- Answers cannot grant tools, expand roots, or approve operations. A revised proposal still needs item approval under B5.

### B7. Notch alerts

- Use a borderless non-activating `NSPanel` for passive alerts. `.statusBar` is a candidate level, not proof it draws above all menu-bar or full-screen content. Phase 0 verifies public AppKit levels, Spaces, full-screen behavior, and menu interaction. Never cover security prompts or the lock screen.
- Use `safeAreaInsets`, `auxiliaryTopLeftArea`, and `auxiliaryTopRightArea` to estimate the notch region when available. The hardware cutout cannot display pixels. Animate visible content below it. Verify safe geometry, scaling, multiple displays, display removal, and menu-bar auto-hide. Use a top-center pill on screens without a notch.
- Content: icon, title, one short line, and Review/Answer or Later/Retry. Keep passive alerts out of keyboard focus. An explicit click can open a key window for typing or approval. Support VoiceOver and Reduce Motion.
- Show one alert at a time and merge bursts. Close after six seconds unless hovered. Keep unresolved items in Needs you and a menu-bar dot. Persist delivery and deferral state so relaunch does not repeat a burst.
- If the app is absent, the helper opens the exact owning bundle with `NSWorkspace.openApplication`, `activates = false`, and a fixed alert-mode argument. The app reads pending state, not paths or commands from arguments. Implement handling for both cold start and an already-running app. Do not trigger onboarding or the launcher on an alert launch.
- Quiet hours delay alerts, not work. Defer private content while the session is locked or inactive. Redact client and file names in passive alerts by default. `CGSessionCopyCurrentDictionary` is not proof of screen-sharing detection. Keep that automatic detection as a phase 0 spike; provide manual presentation mute without claiming automatic coverage.
- No system banners for automations. Remove Luna Task notification delivery when replaced. Keep unrelated timer and command notifications intact. External watchdog banners remain a separate user-controlled setting (B9).

### B8. Automations UI

- Launcher: automation rows with status, next run, last result, and a Needs you section. Verbs: Run Now, Pause/Resume schedule, Cancel Run, Open Last Result, Open Folder, Edit, Duplicate.
- Detail pane: schedule and timezone, kind, runner, account route, model, effort, supported Fast toggle, read scope, script effects, policies, history, and bounded output viewer.
- Templates: Desktop tidy and Downloads sort use proposals. Morning brief uses Writing and its existing data switches. Metrics refresh uses an approved script. Client report templates stay unavailable until their port contracts are proved.
- Test run is real work unless using fixtures. Show the exact script effects before approval. It uses the same locks, safety rules, and duplicate-run guard. Test alerts use only the notch panel.
- Preserve the existing Scheduled view controls for other jobs. Route Jevcast service controls through SMAppService and runner state, not generic launchctl toggles. Codex rows are read-only.

### B9. Codex automations: see, import, run without Codex

- **See**: bounded read-only parsing of `~/.codex/automations/*/automation.toml`. Use a tested TOML subset for the observed version 1 format, including escaped and multiline prompts. No external dependency. Reject duplicate keys, malformed files, symlink escapes, unsupported versions, or mismatched directory/file IDs. Keep unparsed entries visible with an error.
- Read `~/.codex/automation-health/state.json` as optional dated evidence. Missing or stale state is Unknown. Do not label it last completed run. RRULE-derived next time is an estimate until timezone and anchor are confirmed. A Codex URL action is a phase 0 spike; otherwise omit it.
- **Import**: create a paused copy with a new local ID, original source ID/path, source hash, and immutable prompt snapshot. Keep the original model/effort line. Parsed values are suggestions, not authority. Missing or conflicting model, effort, cwd, or timezone blocks enablement. No default `~/Dev/docs` cwd and no silent model fallback.
- Preserve source constraints, including exact model and subagent requirements, client status checks, reporting limits, and no-send rules. Desktop app tools, skills, connectors, and thread context do not automatically exist in `codex exec`. Review these dependencies before enabling a port. Do not run prompt-extracted commands without explicit script review.
- **Double-run guard**: re-read the source before enablement and every scheduled or manual run. Block while ACTIVE or unreadable. A PAUSED file does not prove the old run stopped. Require a handover check for in-flight work and shared script locks. There is no atomic cross-scheduler lock with Codex, so do not promise complete exclusion if the source is later re-enabled.
- **Per-automation port plan**:

  | Codex automation | Jevcast kind | Notes |
  | --- | --- | --- |
  | stein-firm-daily-metrics | script + onFailure report | Confirmed argv: `bun scripts/utils/redesign-daily-metrics.ts --client stein-firm`, cwd docs. Keep structured source checks, script retries, database/dashboard locks, and no commit/deploy. |
  | redesign-daily-metrics | script + onFailure report | Confirmed same script without `--client`. Preserve partial-failure and coverage checks. |
  | robert-parish-daily-metrics | multi-step port, phase 0 | `--client robert-parish` is confirmed. Success must continue to due weekly/monthly reports, PDF and draft creation, validation, visible output, and posting receipts. An onFailure-only agent loses this work. |
  | daily-docs-backup | reviewed script sequence, phase 0 | Docs backup first, then agents backup only on success. Includes checks, commits, pushes, and remote parity proof. Automatic model repair conflicts with v1; block that step pending a reviewed proposal design. |
  | john-trudel-weekly-meta-ads-report | multi-step port, phase 0 | Daily due check, exact Astra workers, bundle writes, report validation, visible report, and receipt writes. It is not a read-only filesystem task and cannot be copied into a restricted agent unchanged. |
  | goodrich-weekly-meta-ads-report, basu-end-to-end-growth-report | import paused | Review script writes, required data sources, client archive gates, and exact worker contracts before porting. |
  | daily-mva-outreach | import paused, unsupported in v1 | Requires Gmail draft and Attio operations not in the proposal schema. Preserve manual sending from Gmail. A local draft card is not a complete port. |
  | global-thread-lifecycle | visible, remains in Codex | Requires supported Codex desktop task-state and mutation tools. Not a standalone CLI port. |

- A metrics script succeeds only when its structured result, required source coverage, output publication, and locks confirm completion. Exit status and a recent file timestamp are insufficient. Preserve reporting dates separately from collection times and partial-day data.
- Robert and John need a durable Jevcast report view and output reference before recording a posting receipt. Verify that the reporting scripts accept this reference and preserve crash reconciliation. Never mark posted merely because a CLI exited or a file exists. Robert's successful due report becomes needsInput for draft review. Nothing is sent externally.
- Do not declare the watchdog unnecessary. It also covers jobs left in Codex. For notch-only coverage, phase 0 must define read-only ingestion and deduplication of its stale/failure state, then a separately authorized change can turn off its external `--notify` behavior. Leave its files and service unchanged in this task. Do not claim global script banners are gone before that handover.

### B10. Clients metrics

- Configure explicit sidecar, dashboard, client identity, and refresh automation paths. Found under `~/Dev/docs/`: Stein at `4-delivery/clients/shantyl-stevens/meta-ads/stein-firm-dashboard.metrics.json`; Robert at `4-delivery/clients/robert-parish/meta-ads/robert-parish-dashboard.metrics.json`; ReDesign at `2-marketing/paid-ads/meta-ads/redesign-pi-firm-ads/2026-08-01-redesign-meta-ads-dashboard.metrics.json`. Do not infer dashboard paths from model output.
- Decode known versions 4 and 5 with explicit field contracts. Stein has `formQualified`, `costPerFormQualified`, and `metaFormQualified`. ReDesign has `paidTaggedForms`, `costPerForm`, and nullable `qualifiedMeetings`. Do not relabel these as generic leads, bookings, retainers, or confirmed buyers.
- Robert has `paidSignupCount`, `costPerPaidSignup`, and `homesClicked`, but its current reporting prompt forbids monetary metrics and has strict lifecycle coverage limits. Its panel must omit money and respect those limits. Do not turn global lifecycle events into attributed buyer conversions or UTC buckets into exact Los Angeles totals.
- Show report range, reporting timezone, collection time, source status, and closed-day coverage separately. Freshness is per required source using `last_success_at`, not `generatedAt`. Six-hour and 24-hour colors describe collection age only. Failure, missing coverage, null, and future timestamps cannot display green success or measured zero.
- Bound file size and validate ownership, configured paths, types, finite numbers, and timestamps. Read one complete snapshot across atomic replacement. Keep the last good snapshot visibly stale after a parse failure. Watch the parent directory and refresh on open because the file inode may change. Unknown versions show Unsupported with no guessed KPIs. Use synthetic fixtures.
- Actions: Open configured dashboard, Refresh now through the automation queue, Show last run. No live Meta calls from the panel. Opening the HTML is explicit; displaying metrics does not load its scripts or remote resources.

### B11. Replace Luna Tasks

- Do not convert tasks automatically at first launch. Provide an explicit local import with a preview, context switches, equivalent schedule, paused destination tasks, and stable source IDs for deduplication. Preserve original definitions and result files as an inert recovery archive. Do not delete defaults or move results before verified import.
- At cutover, stop the old loop and drain active tasks before enabling new tasks. One scheduler owns each task. The old store is not a second runtime or a one-release fallback. Unsupported schedules remain visible for manual repair.
- Keep the Writing request gate and metadata-only activity log in force in the helper. Recheck enabled state and every context switch at send time, including revocation after collection. Store shared policy in an explicit versioned file; the helper cannot assume its UserDefaults domain matches the app.
- Phase 0 must verify EventKit Calendar/Reminders, Desktop/Downloads access, Keychain, and Mail access for the launchd helper and its child processes. Current unread-mail gathering reads the Mail store, which may need Full Disk Access. Apple Events have a separate permission for Mail actions. Do not assume parent TCC grants transfer to a helper or that a headless helper can prompt.
- If helper access cannot meet the contract, keep Writing automation unavailable until a tested app-owned context broker exists. Such a broker needs durable request IDs, expiry, authenticated ownership checks, and minimal context transfer; a Darwin notification alone is not IPC. No silent empty context or fabricated success. Permission requests occur through explicit setup UI.

## Safety summary

- No model-written commands. CLI read-only flags are necessary but not sufficient; isolation is a phase 0 release gate.
- Approved scripts can use the network and write files under Ryan's accounts. CLI prompts and permitted context go to their providers. Writing still sends opt-in context to OpenRouter. Do not describe this as no network use.
- Deterministic path checks, race-resistant application, exact approvals, and recovery journals are required. Trash and undo are not guaranteed recovery in all cases.
- Codex registry reads never mutate schedules or threads. Imports start paused and retain provenance.
- Private outputs stay local with owner-only access and bounded retention. Activity logs contain metadata only. Transcripts and provider sessions may contain content and need separate controls.

## Phases

0. **Spikes, required before implementation claims**: prove helper packaging, SMAppService signing/location support, launchd restart and child cleanup, update/unregister behavior, helper TCC and Keychain, CLI tool/config/read isolation and resume, exact account/model/tier support, notch geometry/focus, race-resistant file apply/Trash/undo, and client report dependencies. Record pass/fail evidence for each supported OS/signing/CLI combination. No time estimate or automatic fallback.
1. **Part A**: rename code/UI, keep canonical storage identifiers, verify model capabilities, split effort and supported Fast, update demo snapshots.
2. **Core**: schedule engine, versioned store, transitions, request protocol, proposal validation, metrics decoding, and tests.
3. **Runner helper**: registration, persistent loop, claims, resource locks, scripts, proved CLI adapters, process supervision, and recovery.
4. **UI**: Automations window, launcher source, templates, test run, and Scheduled groups.
5. **Notch alerts** and menu-bar dot. Preserve non-automation notifications.
6. **Proposals and ask mode**: approval window, secure apply, journal reconciliation, conditional undo, and safe resume.
7. **Codex see and import**: port proved workflows one at a time, metrics first. Pause and drain the original before a real port run. Compare saved outputs, not two concurrent collectors. Keep unsupported workflows paused or in Codex. Do not claim all six active jobs are portable.
8. **Clients panel** with per-client metric meanings and source coverage.
9. **Explicit Luna Tasks import** and old-loop cutover. No automatic data deletion.

## Tests and proof

- Unit: all nine observed rules with confirmed anchors/timezones, DST, clock jumps, catch-up, overlap, unsupported TOML, revision conflicts, and request replay.
- Security: traversal, sibling-prefix roots, symlinks swapped during apply, hard links, destination races, stale approvals, forged manifests, directory dependencies, prompt injection, config hooks, model commands, and writes to control state. Test real CLI behavior in phase 0; fake CLIs cannot prove sandbox safety.
- Recovery: crash before/after claim, spawn, output persistence, each apply/journal boundary, and report receipt. Test descendants, bounded pipes, cancellation, missing session, duplicate answers, partial writes, and revoked permissions.
- Data: synthetic version 4/5 sidecars, null KPIs, partial coverage, UTC/LA differences, unknown versions, atomic replacement, and stale last-good display. Verify explicit legacy import without duplicate scheduling or data loss.
- Integration: fake CLIs selected by explicit test paths emit bounded stream fixtures. Test parsing and supervision without quota or client data.
- Future implementation checks: `swift test` and `scripts/build.sh`. Neither is run for this document-only review.
- Manual proof, reported separately: registration by signing mode, login/reboot, quit app while work runs, sleep/wake, helper permissions, app update, real isolated Codex/Claude runs, notch on built-in/external displays and full-screen Spaces, keyboard/VoiceOver, approve/undo/conflict recovery, and metrics/report handover. No UI or runtime spike was performed during this review.

## Open questions for Ryan

1. Default runner for new agent tasks: Codex or Claude, after the isolation gate passes.
2. Which supported signing mode should be required if ad-hoc registration fails in phase 0?
3. Should the later port include a separate draft/report operations schema for the workflows blocked in B9?

Quill is the chosen feature name. Needs-input and final-failure alerts use the notch panel. Unsupported Codex desktop workflows remain visible in Codex until a complete port is designed.
