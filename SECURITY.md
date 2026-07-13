# Security Policy

## Reporting a vulnerability

Use the repository's **Security** tab to submit a private vulnerability report when that option is available. Include the affected version, macOS version, reproduction steps, and impact, but do not include Codex credentials, account identifiers, prompts, messages, or other private local data.

If private reporting is unavailable, open a minimal GitHub issue asking the maintainer for a private contact channel. Do not publish exploit details or secrets in the issue.

## Scope

Security-sensitive areas include update signature and digest validation, installer path handling, local Codex executable discovery, app-server transport, and unintended collection or export of private Codex data.

This project relies on private or experimental Codex interfaces. Compatibility breakage by itself is not a security vulnerability unless it crosses a trust, authorization, privacy, or integrity boundary.
