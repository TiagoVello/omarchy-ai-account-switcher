# Repository guidance

This repository is the Omarchy Quattro plugin
`acrogenesis.ai-account-switcher`.

## Invariants

- Never print provider tokens or persist them outside the private account
  stores.
- Keep the Codex and Claude stores separate; the same email can be saved for
  both providers.
- A Claude account is identified by its organization together with its
  `accountUuid` or email, because seats sharing an email differ only by
  organization. Compare the organization only when both sides record one, so
  stores written before it was saved keep matching.
- Adding an account must use an isolated `CODEX_HOME` or
  `CLAUDE_CONFIG_DIR` and must not log out or alter the live login.
- Each saved account has a stable private provider home. Selection must never
  rewrite the shared `~/.codex` or `~/.claude` credentials.
- Launch Codex with the account's `CODEX_HOME` and Claude with the account's
  `CLAUDE_CONFIG_DIR`, so running sessions retain the login they started with.
- Installed command routers must honor an already-set provider home, resolve
  the real CLI without recursion, and preserve any replaced command as a
  recoverable private backup. Their mise alias fragment must also be private,
  reversible, and take precedence over mise-managed provider binaries.
- Retain refreshed tokens from each stable account home and seed Claude homes
  with existing unrelated `mcpOAuth` data without modifying the shared file.
- The saved Claude account matching the original shared `~/.claude.json`
  identity owns the existing `~/.claude` prompt and project history. Link only
  that account to the shared history; keep every other account's history
  isolated, and back up migrated files before replacing them with links.
- Credential directories and files must remain `0700` and `0600` respectively,
  and writers must refuse destination symlinks.

## Validation

Run `tests/test_accounts.sh`, the launcher/router integration test, both add-account
integration tests, Bash syntax checks, `omarchy plugin validate .`, and QML
linting for changed files. For bar or panel changes, also reload the shell and
verify the live IPC and rendered panel.

Do not commit, push, publish, release, or create project-management work unless
the user explicitly requests it.
