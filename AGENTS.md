# Repository guidance

This repository is a Claude-only fork of the Omarchy Quattro plugin
`acrogenesis.ai-account-switcher`. Claude Code is the only provider; there is
no Codex support and no provider abstraction to keep generic.

## Invariants

- Never print provider tokens or persist them outside the private account
  stores.
- A Claude account is identified by its organization together with its
  `accountUuid` or email, because seats sharing an email differ only by
  organization. Compare the organization only when both sides record one, so
  stores written before it was saved keep matching.
- Adding an account must use an isolated `CLAUDE_CONFIG_DIR` and must not log
  out or alter the live login.
- Each saved account has a stable private home under `homes/claude/`.
  Selection must never rewrite the shared `~/.claude` credentials.
- Launch Claude with the account's `CLAUDE_CONFIG_DIR`, so running sessions
  retain the login they started with.
- The installed command router must honor an already-set `CLAUDE_CONFIG_DIR`,
  resolve the real CLI without recursion, and preserve any replaced command as
  a recoverable private backup. Its mise alias fragment must also be private,
  reversible, and take precedence over a mise-managed `claude` binary.
- Retain refreshed tokens from each stable account home and seed new homes
  with existing unrelated `mcpOAuth` data without modifying the shared file.
- The saved Claude account matching the original shared `~/.claude.json`
  identity owns the existing `~/.claude` prompt and project history. Link only
  that account to the shared history; keep every other account's history
  isolated, and back up migrated files before replacing them with links.
- Credential directories and files must remain `0700` and `0600` respectively,
  and writers must refuse destination symlinks.

## Validation

Run `tests/test_accounts.sh`, the launcher/router integration test, the
add-account integration test, `tests/test_qml_safety.sh`, Bash syntax checks,
and `omarchy plugin validate .`. For bar or panel changes, also reload the shell and
verify the live IPC and rendered panel.

Do not commit, push, publish, release, or create project-management work unless
the user explicitly requests it.
