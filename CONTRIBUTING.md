# Contributing

Thanks for taking interest. A few things to set expectations:

## This is a side project

- **Best-effort, no SLA.** Issue triage and PR review happen when time allows.
- The maintainer's primary work is private; this public repo is a periodic snapshot.

## Issues

Open an issue for bugs / feature requests. Include:

- macOS version + iPhone model + iOS version
- What you expected vs what happened
- Helper logs at `/Library/Logs/locspoof-helper.{out,err}.log` if relevant
- For build failures: `xcodebuild` output

## Security issues

**Please do not file public issues for security concerns.** Use [GitHub Security Advisories](../../security/advisories/new) for private disclosure. The maintainer will fix in a private branch and coordinate disclosure with the next release.

## Pull requests

PRs are welcome but please understand the workflow:

- This repo's `main` is **force-pushed** from a private upstream (each release replaces history).
- PRs cannot be merged in the traditional sense — they get **cherry-picked into the private repo** and shipped in the next release.
- The PR will be closed with a note linking to the release that included your changes.

For non-trivial changes, **open an issue first** to discuss scope before sending a PR.

## What's not in this repo

- Dev iteration scripts (e.g. local install automation)
- Internal architecture notes for the maintainer

These live in the private upstream and aren't relevant to consumers of the released app.

## Code conventions

- Swift: 4-space indent, idiomatic SwiftUI / Concurrency
- Python: stdlib only in `host/`; no pip-install dependencies
- Commit message format: `Category: lowercase description` (e.g. `fix: helper auto-recovery on iphone reconnect`)

## License

By contributing, you agree your contributions are licensed under GPL-3.0 (same as the project).
