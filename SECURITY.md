# Security

## Report a problem

Report security problems privately. Do not open a public issue.

Use **Report a vulnerability** on the repository's [Security tab](https://github.com/RyanErkal/jevcast/security/advisories/new). Include the app version (About Jevcast), your macOS version, and the steps that show the problem.

## Supported versions

Only the newest release gets security fixes. Update from **Check for Updates…** in the app menu or from the [releases page](https://github.com/RyanErkal/jevcast/releases).

## What is in scope

- Anything that lets a web page, mail message, file, or model reply run code or commands through the app.
- Leaks of file paths, clipboard contents, audio, dictation transcripts, or a TypeSafe or OpenRouter key.
- Context sent to Quill while its switch in Settings › AI › Quill is off.
- An automation agent that gets more access than its task allows, for example a write outside its folder, the network when the task does not allow it, or a command tool in a Claude run.
- A proposal applied outside the roots the user set, applied without approval, or applied to a file that changed after the check. An undo that overwrites a file.
- A script task that runs a program or arguments the user did not type or approve.
- Script secrets that leave the Keychain other than to the script that uses them.
- Misuse of the Accessibility or Input Monitoring permission, for example moving or reading windows the user did not target, or keeping or sending typing beyond the Hyper and dictation keys.
- Update checks that could make the app download or open something the user did not choose.

## Design limits

- Natural-language matching can only return one of the candidate IDs the app sent. The app rejects any other reply and never runs text from a reply.
- Quill only writes text. It never picks or runs an action. Code checks each request against the context switches and logs each send without its text.
- Automations run the `codex` or `claude` CLI that the user installed and signed in to. Access is enforced by the CLI's sandbox or a fixed tool list, not by prompt text. Jevcast never passes a bypass or full-access flag, and it removes API-key variables from agent runs. What those CLIs send to their providers is outside Jevcast.
- Mail HTML never runs scripts. It loads web images, fonts, and style sheets by default, so a sender can see when a message opens. The user can turn this off in the mail window.
- Apple Events use fixed script text. Values reach a script only as arguments.
- The update check only reads the version and page of the newest GitHub release. It never downloads or installs anything.
- The TypeSafe or OpenRouter key is stored in the macOS Keychain. It is sent only to `api.typesafe.ai` or `openrouter.ai`. Script secrets are stored in the Keychain too.
- Clipboard history, dictation transcripts, and automation files are readable only by the user's account. Another process that runs as the same user can still read them.
