#!/bin/bash

set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"

cleanup() { rm -rf -- "$test_dir"; }
trap cleanup EXIT

fake_bin="$test_dir/bin"
switcher_dir="$test_dir/switcher"
live_claude="$test_dir/live-claude"
mkdir -p "$fake_bin" "$live_claude"
ln -s "$project_dir/tests/fake_claude.sh" "$fake_bin/claude"

jq -n '{claudeAiOauth:{accessToken:"access-one",refreshToken:"refresh-one"},
  mcpOAuth:{keep:{accessToken:"mcp-one"}}}' >"$live_claude/.credentials.json"
jq -n '{oauthAccount:{emailAddress:"one@example.com",accountUuid:"claude-one"}}' \
  >"$live_claude/.claude.json"

common_env=(
  PATH="$fake_bin:$PATH"
  HOME="$test_dir"
  CLAUDE_CONFIG_DIR="$live_claude"
  OMARCHY_AI_SWITCHER_DIR="$switcher_dir"
  FAKE_CLAUDE_LOG="$test_dir/claude.log"
)

env "${common_env[@]}" bash "$project_dir/ai_accounts.sh" import-current ClaudeOne >/dev/null
claude_id=$(jq -r '.accounts[0].id' "$switcher_dir/claude-accounts.json")
claude_live_hash=$(sha256sum "$live_claude/.credentials.json" | cut -d' ' -f1)
claude_output=$(env "${common_env[@]}" bash "$project_dir/LaunchAccount.sh" "$claude_id")
claude_home="$switcher_dir/homes/claude/$claude_id"
jq -e --arg home "$claude_home" '
  select(.launched == true and .home == $home and .email == "one@example.com")
' <<<"$(tail -n 1 <<<"$claude_output")" >/dev/null
[[ $(sha256sum "$live_claude/.credentials.json" | cut -d' ' -f1) == "$claude_live_hash" ]]

# The installed command router makes plain `claude` follow the selection, while an
# explicit CLAUDE_CONFIG_DIR bypasses routing and removal restores the old command.
wrapper_bin="$test_dir/wrapper-bin"
mkdir -p "$wrapper_bin"
printf '#!/bin/bash\necho original-claude\n' >"$wrapper_bin/claude"
chmod 755 "$wrapper_bin/claude"

router_env=(
  PATH="$wrapper_bin:$fake_bin:/usr/bin"
  HOME="$test_dir"
  CLAUDE_CONFIG_DIR=
  OMARCHY_AI_SWITCHER_DIR="$switcher_dir"
  OMARCHY_AI_SWITCHER_BIN_DIR="$wrapper_bin"
  OMARCHY_AI_SWITCHER_MISE_CONF_DIR="$test_dir/mise/conf.d"
  OMARCHY_AI_SWITCHER_PLUGIN_DIR="$project_dir"
  FAKE_CLAUDE_LOG="$test_dir/claude.log"
)

mise_fragment="$test_dir/mise/conf.d/omarchy-ai-account-switcher.toml"
mkdir -p "$(dirname "$mise_fragment")"
printf '# existing config\n[shell_alias]\nll = "ls -la"\n' >"$mise_fragment"
env "${router_env[@]}" bash "$project_dir/InstallCommandWrappers.sh" install >/dev/null
rg -q '^\[shell_alias\]$' "$mise_fragment"
rg -Fq "claude = \"$wrapper_bin/claude\"" "$mise_fragment"
rg -q '^# existing config$' "$switcher_dir/wrapper-backups/mise-conf-fragment.toml"
env "${router_env[@]}" bash "$project_dir/ai_accounts.sh" status |
  jq -e '.command_wrappers_enabled == true' >/dev/null

plain_claude=$(env "${router_env[@]}" "$wrapper_bin/claude")
jq -e --arg home "$claude_home" '
  select(.launched == true and .home == $home and .email == "one@example.com")
' <<<"$plain_claude" >/dev/null

explicit_claude=$(env "${router_env[@]}" CLAUDE_CONFIG_DIR="$live_claude" "$wrapper_bin/claude")
jq -e --arg home "$live_claude" 'select(.launched == true and .home == $home)' \
  <<<"$explicit_claude" >/dev/null

env "${router_env[@]}" bash "$project_dir/InstallCommandWrappers.sh" remove >/dev/null
rg -q '^# existing config$' "$mise_fragment"
rg -q '^ll = "ls -la"$' "$mise_fragment"
rg -q 'original-claude' "$wrapper_bin/claude"

# A stale backup must never cause a subsequently changed command to be lost.
mkdir -p "$switcher_dir/wrapper-backups"
printf '#!/bin/bash\necho previous-claude\n' >"$switcher_dir/wrapper-backups/claude"
if env "${router_env[@]}" bash "$project_dir/InstallCommandWrappers.sh" install >/dev/null 2>&1; then
  echo "Expected router installation to reject a changed command with a stale backup" >&2
  exit 1
fi
rg -q 'original-claude' "$wrapper_bin/claude"

echo "Per-account launcher and command-router isolation tests passed"
