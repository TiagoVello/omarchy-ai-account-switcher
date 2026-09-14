# Claude Account Switcher for Omarchy

A native Omarchy Quattro bar plugin for saving and switching personal Claude
Code accounts.

![Claude Account Switcher panel showing fictional Claude accounts with usage bars](preview.png)

## Features

- A saved Claude account list in one compact menubar panel.
- Shows each saved account's remaining Claude plan capacity so the account with
  the most headroom is easy to choose.
- Uses the official `claude auth login` flow.
- Gives every account a stable isolated `CLAUDE_CONFIG_DIR`.
- Opens the selected account in a new terminal without rewriting the shared
  Claude login.
- Optionally routes the ordinary `claude` command to the selected account,
  while honoring an explicitly set `CLAUDE_CONFIG_DIR`.
- Lets existing sessions keep the account they started with while other
  accounts run alongside them.
- Saves several Claude seats that share one email address, such as a personal
  subscription and a team seat, as separate accounts told apart by their
  organization.
- Keeps the original Claude profile's existing prompt and resume history with
  that account, while new accounts retain independent histories.
- Retains credentials refreshed inside each account home and seeds new homes
  with existing unrelated `mcpOAuth` data.
- Keeps credential stores local with `0700` directory and `0600` file modes.

## Requirements

- Omarchy Quattro with plugin support
- `bash`, `jq`, `flock`, and `base64` (included in Omarchy's base system)
- `claude` for Claude accounts

## Install

```bash
omarchy plugin add https://github.com/TiagoVello/omarchy-ai-account-switcher.git --enable
```

The plugin appears in the right side of the bar. Open it and save the login
currently active on the machine. Select any saved account and press **Open
Claude as ...** to start a terminal using that account's isolated
`CLAUDE_CONFIG_DIR`. Selecting another account later does not change any
already-open session.

**Add another account** immediately launches Claude's official login in an
isolated temporary home; there is no pre-login confirmation prompt. After
login, the plugin promotes it to a stable private account home. No operation
requires closing active Claude sessions.

Plan usage is fetched through the installed `claude` CLI when the panel opens
and cached in memory for five minutes. It is never added to the credential
store. Accounts whose plan does not expose limits remain selectable and show
that plan usage was not reported.

Press **Make the plain claude command follow selection** once to install a
recoverable command router in `~/.local/bin` plus a private mise shell-alias
fragment that keeps that router ahead of a mise-managed `claude` binary. After
that, ordinary new `claude` processes use the menubar selection from any
terminal. Processes already running—and new conversations created inside one of
those existing processes—keep the account that process started with.

## Local data

Saved credentials are kept outside the plugin checkout:

```text
~/.config/omarchy/ai-account-switcher/
├── claude-accounts.json
└── homes/
    └── claude/ACCOUNT_ID/
```

If terminal command routing is enabled, an existing command at the destination
or mise fragment is preserved under `wrapper-backups/` before the switcher
installs its router and `~/.config/mise/conf.d/omarchy-ai-account-switcher.toml`.

The homes contain each account's credentials, refreshed tokens, and session
state. Common user configuration such as Claude settings and plugins is linked
from the normal Claude home when an account home is first created. Account
homes begin with the shared credential document's unrelated MCP OAuth entries,
then refresh independently.

The saved account whose identity matches the original `~/.claude.json` profile
continues to use the prompt history and project transcripts already stored in
`~/.claude`. Other accounts keep their own histories in their isolated homes.
If an older plugin version already created isolated history for the original
account, it is merged back without overwriting existing transcripts and
retained under `history-backups/claude/ACCOUNT_ID/` before the account is
linked to the original history.

Removing the plugin does not delete saved credentials. Delete the directory
above separately if you also want to remove the saved account copies.

## Remove

If terminal command routing is enabled, first restore the command exactly as it
was before enabling it:

```bash
bash ~/.config/omarchy/plugins/acrogenesis.ai-account-switcher/InstallCommandWrappers.sh remove
```

Then remove the plugin:

```bash
omarchy plugin remove acrogenesis.ai-account-switcher
```

The command removes the plugin but deliberately leaves the private account
store intact. To remove those additional local copies too:

```bash
rm -r ~/.config/omarchy/ai-account-switcher
```

This does not log out Claude and does not delete its live configuration.

## Security model

This plugin reads the normal Claude authentication file only when the user
explicitly saves that login. Selecting or opening a saved account does not
rewrite those shared files. Saved credentials never leave the machine, are
excluded from command and QML output, and are written under private `0700`
directories with `0600` files. Account changes are locked and atomic, and
destination symlinks are rejected. Terminal routing is installed only through
the explicit panel action; the replaced command and mise configuration are
backed up and restorable.

Review the source before installation. Omarchy plugins execute as unsandboxed
user code; marketplace validation is compatibility checking, not a security
audit.

## IPC

```bash
omarchy-shell acrogenesis.ai-account-switcher status
omarchy-shell acrogenesis.ai-account-switcher refresh
omarchy-shell acrogenesis.ai-account-switcher toggle
omarchy-shell acrogenesis.ai-account-switcher saveCurrent "Personal"
omarchy-shell acrogenesis.ai-account-switcher switchAccount ACCOUNT_ID
omarchy-shell acrogenesis.ai-account-switcher launchSelected
omarchy-shell acrogenesis.ai-account-switcher enableCommandSwitching
```

## Development

```bash
bash tests/test_accounts.sh
bash tests/test_add_claude_account.sh
bash tests/test_launch_account.sh
bash tests/test_qml_safety.sh
bash -n ai_accounts.sh AddClaudeAccount.sh LaunchAccount.sh CommandWrapper.sh InstallCommandWrappers.sh tests/*.sh
omarchy plugin validate .
```

## Relationship to upstream

This is a Claude-only fork of
[acrogenesis/omarchy-ai-account-switcher](https://github.com/acrogenesis/omarchy-ai-account-switcher),
which also supports Codex. The Codex provider is removed here; everything else
follows upstream.

## Design references

The per-session isolation model uses Anthropic's documented configuration root,
[`CLAUDE_CONFIG_DIR`](https://code.claude.com/docs/en/env-vars), which Anthropic
explicitly supports for running multiple accounts side by side.

Claude credential behavior was informed by
[Symbioose/claude-account-switcher](https://github.com/Symbioose/claude-account-switcher).
The implementation here is native to Omarchy and does not bundle that tool.

## License

MIT
