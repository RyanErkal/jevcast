# Security

## Report a problem

Report security problems privately. Do not open a public issue.

Use **Report a vulnerability** on the repository's [Security tab](https://github.com/RyanErkal/jev-launcher/security/advisories/new). Include the app version (About Jev Launcher), your macOS version, and the steps that show the problem.

## Supported versions

Only the newest release gets security fixes. Update from **Check for Updates…** in the app menu or from the [releases page](https://github.com/RyanErkal/jev-launcher/releases).

## What is in scope

- Anything that lets a web page, file, or model reply run code or commands through the app.
- Leaks of file paths, clipboard contents, audio, or the TypeSafe API key.
- Misuse of the Accessibility permission, for example moving or reading windows the user did not target.
- Update checks that could make the app download or open something the user did not choose.

## Design limits

- Natural-language matching can only return one of the candidate IDs the app sent. The app rejects any other reply and never runs text from a reply.
- The update check only reads the version and page of the newest GitHub release. It never downloads or installs anything.
- The TypeSafe key is stored in the macOS Keychain and is sent only to `api.typesafe.ai`.
