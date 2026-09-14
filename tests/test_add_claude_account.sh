#!/bin/bash

set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"

cleanup() {
  rm -rf -- "$test_dir"
}

trap cleanup EXIT

current_home="$test_dir/current-claude"
switcher_dir="$test_dir/switcher"
fake_bin="$test_dir/bin"
new_credentials="$test_dir/new-credentials.json"
new_state="$test_dir/new-state.json"
fake_log="$test_dir/claude.log"

mkdir -p "$current_home" "$fake_bin"
ln -s "$project_dir/tests/fake_claude.sh" "$fake_bin/claude"

jq -n '{
  claudeAiOauth: {
    accessToken: "current-access",
    refreshToken: "current-refresh",
    subscriptionType: "team"
  },
  mcpOAuth: {keep: {accessToken: "mcp-current"}}
}' >"$current_home/.credentials.json"
jq -n '{oauthAccount: {
  emailAddress: "current@example.com",
  accountUuid: "uuid-current",
  organizationName: "Current Org"
}}' >"$current_home/.claude.json"

jq -n '{claudeAiOauth: {
  accessToken: "second-access",
  refreshToken: "second-refresh",
  subscriptionType: "pro"
}}' >"$new_credentials"
jq -n '{oauthAccount: {
  emailAddress: "second@example.com",
  accountUuid: "uuid-second",
  organizationName: "Second Org"
}}' >"$new_state"

before_hash="$(sha256sum "$current_home/.credentials.json" | cut -d' ' -f1)"

env \
  PATH="$fake_bin:$PATH" \
  HOME="$test_dir" \
  CLAUDE_CONFIG_DIR="$current_home" \
  OMARCHY_AI_SWITCHER_DIR="$switcher_dir" \
  FAKE_CLAUDE_LOG="$fake_log" \
  bash "$project_dir/ai_accounts.sh" import-current >/dev/null

printf 'Second\n\n' | env \
  PATH="$fake_bin:$PATH" \
  HOME="$test_dir" \
  CLAUDE_CONFIG_DIR="$current_home" \
  OMARCHY_AI_SWITCHER_DIR="$switcher_dir" \
  FAKE_CLAUDE_CREDENTIALS="$new_credentials" \
  FAKE_CLAUDE_STATE="$new_state" \
  FAKE_CLAUDE_LOG="$fake_log" \
  bash "$project_dir/AddClaudeAccount.sh" >"$test_dir/output.txt"

after_hash="$(sha256sum "$current_home/.credentials.json" | cut -d' ' -f1)"

[[ $before_hash == "$after_hash" ]]
rg -q '^auth login$' "$fake_log"
if rg -q 'auth logout' "$fake_log"; then exit 1; fi
jq -e '.accounts | length == 2' "$switcher_dir/claude-accounts.json" >/dev/null
jq -e '.accounts[] | select(.name == "current@example.com")' "$switcher_dir/claude-accounts.json" >/dev/null
jq -e '.accounts[] | select(.name == "Second")' "$switcher_dir/claude-accounts.json" >/dev/null
jq -e '.active_account_id as $active | .accounts[] | select(.id == $active and .name == "current@example.com")' \
  "$switcher_dir/claude-accounts.json" >/dev/null
if rg -q 'Press Enter to continue|Name for the current' "$test_dir/output.txt"; then exit 1; fi
rg -q 'new Claude account is saved' "$test_dir/output.txt"

echo "Claude add-account isolation test passed"
