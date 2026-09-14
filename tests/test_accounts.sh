#!/bin/bash

set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
checks=0

cleanup() { rm -rf -- "$test_root"; }
trap cleanup EXIT

check() {
  "$@"
  checks=$((checks + 1))
}

reset_fixture() {
  fixture="$test_root/$1"
  switcher_dir="$fixture/switcher"
  codex_home="$fixture/codex"
  claude_home="$fixture/claude"
  fake_bin="$fixture/bin"
  fake_log="$fixture/claude.log"
  fake_codex_log="$fixture/codex.log"
  mkdir -p "$codex_home" "$claude_home" "$fake_bin"
  ln -s "$project_dir/tests/fake_ps.sh" "$fake_bin/ps"
  ln -s "$project_dir/tests/fake_claude.sh" "$fake_bin/claude"
  ln -s "$project_dir/tests/fake_codex.sh" "$fake_bin/codex"
  export HOME="$fixture"
  export CODEX_HOME="$codex_home"
  export CLAUDE_CONFIG_DIR="$claude_home"
  export OMARCHY_AI_SWITCHER_DIR="$switcher_dir"
  export FAKE_CLAUDE_LOG="$fake_log"
  export FAKE_CODEX_LOG="$fake_codex_log"
  export PATH="$fake_bin:$original_path"
  unset FAKE_PS_OUTPUT
}

write_codex_chatgpt() {
  local account=$1 suffix=$2
  jq -n --arg account "$account" --arg suffix "$suffix" '{
    auth_mode: "chatgpt",
    tokens: {
      id_token: ("header." + $suffix + ".signature"),
      access_token: ("access-" + $suffix),
      refresh_token: ("refresh-" + $suffix),
      account_id: $account
    }
  }' >"$codex_home/auth.json"
}

write_claude() {
  local email=$1 account_uuid=$2 suffix=$3 org=${4:-Example} org_uuid=${5:-}
  jq -n --arg suffix "$suffix" '{
    claudeAiOauth: {
      accessToken: ("access-" + $suffix),
      refreshToken: ("refresh-" + $suffix),
      expiresAt: 2000000000000,
      subscriptionType: "team"
    },
    mcpOAuth: {example: {accessToken: "mcp-token"}}
  }' >"$claude_home/.credentials.json"
  jq -n --arg email "$email" --arg uuid "$account_uuid" --arg org "$org" \
    --arg org_uuid "$org_uuid" '{
    theme: "dark",
    oauthAccount: ({
      emailAddress: $email,
      accountUuid: $uuid,
      organizationName: $org
    } + (if $org_uuid == "" then {} else {organizationUuid: $org_uuid} end))
  }' >"$claude_home/.claude.json"
}

helper() { bash "$project_dir/ai_accounts.sh" "$@"; }

original_path=$PATH

# Codex: private stores, stable homes, sanitized status, and token refreshes.
reset_fixture codex-main
write_codex_chatgpt account-one one
helper import-current codex One >/dev/null
first_codex=$(jq -r '.accounts[] | select(.name == "One").id' "$switcher_dir/codex-accounts.json")
first_codex_home="$switcher_dir/homes/codex/$first_codex"
check test "$(stat -c '%a' "$switcher_dir")" = 700
check test "$(stat -c '%a' "$switcher_dir/codex-accounts.json")" = 600
check test "$(stat -c '%a' "$first_codex_home")" = 700
check test "$(stat -c '%a' "$first_codex_home/auth.json")" = 600
status=$(helper status)
check jq -e '.providers.codex.accounts[0] |
  .name == "One" and .is_active == true and has("auth_data") == false' <<<"$status" >/dev/null

write_codex_chatgpt account-one rotated
helper import-current codex >/dev/null
check jq -e '.accounts | length == 1' "$switcher_dir/codex-accounts.json" >/dev/null
check jq -e '.accounts[0].auth_data.refresh_token == "refresh-rotated" and .accounts[0].name == "One"' \
  "$switcher_dir/codex-accounts.json" >/dev/null
check jq -e '.tokens.refresh_token == "refresh-rotated"' "$first_codex_home/auth.json" >/dev/null

write_codex_chatgpt account-two two
helper import-current codex Two --inactive >/dev/null
second_codex=$(jq -r '.accounts[] | select(.name == "Two").id' "$switcher_dir/codex-accounts.json")
second_codex_home="$switcher_dir/homes/codex/$second_codex"
check jq -e --arg id "$first_codex" '.active_account_id == $id and (.accounts | length == 2)' \
  "$switcher_dir/codex-accounts.json" >/dev/null
check jq -e '.tokens.account_id == "account-two"' "$second_codex_home/auth.json" >/dev/null
codex_usage=$(helper usage codex "$second_codex")
check jq -e '.ok and .available and .provider == "codex" and
  (.windows | map({key, used_percent}) == [
    {key:"five_hour",used_percent:27},{key:"seven_day",used_percent:61}
  ])' <<<"$codex_usage" >/dev/null

# Selection never mutates the shared live login; isolated refreshes flow back to the private store.
live_codex_hash=$(sha256sum "$codex_home/auth.json" | cut -d' ' -f1)
helper switch codex "$second_codex" >/dev/null
jq '.tokens.refresh_token = "refresh-two-rotated"' "$second_codex_home/auth.json" >"$fixture/rotated.json"
mv "$fixture/rotated.json" "$second_codex_home/auth.json"
launch=$(helper prepare-launch codex "$second_codex")
check jq -e --arg home "$second_codex_home" '.ok and .home == $home and .name == "Two"' <<<"$launch" >/dev/null
helper switch codex "$first_codex" >/dev/null
check test "$(sha256sum "$codex_home/auth.json" | cut -d' ' -f1)" = "$live_codex_hash"
check jq -e '.accounts[] | select(.name == "Two") | .auth_data.refresh_token == "refresh-two-rotated"' \
  "$switcher_dir/codex-accounts.json" >/dev/null

# API-key accounts remain private and prepare their own homes.
jq -n '{auth_mode:"api_key",OPENAI_API_KEY:"sk-test-one"}' >"$codex_home/auth.json"
helper import-current codex KeyOne >/dev/null
jq -n '{auth_mode:"api_key",OPENAI_API_KEY:"sk-test-two"}' >"$codex_home/auth.json"
helper import-current codex KeyTwo >/dev/null
key_one=$(jq -r '.accounts[] | select(.name == "KeyOne").id' "$switcher_dir/codex-accounts.json")
helper switch codex "$key_one" >/dev/null
check jq -e '.OPENAI_API_KEY == "sk-test-one"' "$switcher_dir/homes/codex/$key_one/auth.json" >/dev/null
check jq -e '.providers.codex.accounts[] | select(.name == "KeyOne") | has("auth_data") == false' \
  <<<"$(helper status)" >/dev/null

# Selection stays available while sessions are running.
write_codex_chatgpt account-two two
helper import-current codex Two >/dev/null
export FAKE_PS_OUTPUT='101 pts/1 codex codex --model test'
selected=$(helper switch codex "$first_codex")
check jq -e '.ok and (.message | contains("new sessions"))' <<<"$selected" >/dev/null
check jq -e '.providers.codex.running_count == 1 and .providers.codex.can_switch == true' \
  <<<"$(helper status)" >/dev/null
unset FAKE_PS_OUTPUT

helper rename codex "$first_codex" Work >/dev/null
check jq -e --arg id "$first_codex" '.accounts[] | select(.id == $id) | .name == "Work"' \
  "$switcher_dir/codex-accounts.json" >/dev/null
helper remove codex "$first_codex" >/dev/null
check jq -e --arg id "$first_codex" '[.accounts[] | select(.id == $id)] | length == 0' \
  "$switcher_dir/codex-accounts.json" >/dev/null
check test ! -e "$first_codex_home"

# Store writes refuse destination symlinks.
reset_fixture codex-symlink
write_codex_chatgpt account-one one
mkdir -p "$switcher_dir"
printf '{"untouched":true}\n' >"$fixture/victim.json"
ln -s "$fixture/victim.json" "$switcher_dir/codex-accounts.json"
set +e
symlink_result=$(helper import-current codex One)
symlink_rc=$?
set -e
check test "$symlink_rc" = 1
check jq -e '.untouched == true' "$fixture/victim.json" >/dev/null
check jq -e '.error | contains("symlink")' <<<"$symlink_result" >/dev/null

# Claude: stable homes seed MCP credentials while keeping Claude logins isolated.
reset_fixture claude-main
write_claude one@example.com uuid-one one 'One Org'
helper import-current claude One >/dev/null
check test "$(stat -c '%a' "$switcher_dir/claude-accounts.json")" = 600
check jq -e '.providers.claude.accounts[0] |
  .name == "One" and .email == "one@example.com" and .is_active == true and
  has("credentials") == false and has("oauth_account") == false' <<<"$(helper status)" >/dev/null
first_claude=$(jq -r '.accounts[0].id' "$switcher_dir/claude-accounts.json")
first_claude_home="$switcher_dir/homes/claude/$first_claude"
check jq -e '.claudeAiOauth.refreshToken == "refresh-one" and .mcpOAuth.example.accessToken == "mcp-token"' \
  "$first_claude_home/.credentials.json" >/dev/null

write_claude two@example.com uuid-two two 'Two Org'
helper import-current claude Two --inactive >/dev/null
second_claude=$(jq -r '.accounts[] | select(.name == "Two").id' "$switcher_dir/claude-accounts.json")
second_claude_home="$switcher_dir/homes/claude/$second_claude"
check jq -e --arg id "$first_claude" '.active_account_id == $id and (.accounts | length == 2)' \
  "$switcher_dir/claude-accounts.json" >/dev/null
claude_usage=$(helper usage claude "$second_claude")
check jq -e '.ok and .available and .provider == "claude" and
  (.windows | map({key, used_percent}) == [
    {key:"five_hour",used_percent:34},{key:"seven_day",used_percent:72}
  ])' <<<"$claude_usage" >/dev/null

live_claude_hash=$(sha256sum "$claude_home/.credentials.json" | cut -d' ' -f1)
helper switch claude "$second_claude" >/dev/null
jq '.claudeAiOauth.refreshToken = "refresh-two-rotated" |
  .mcpOAuth.other = {accessToken:"keep-me"}' "$second_claude_home/.credentials.json" >"$fixture/rotated.json"
mv "$fixture/rotated.json" "$second_claude_home/.credentials.json"
launch=$(helper prepare-launch claude "$second_claude")
check jq -e --arg home "$second_claude_home" '.ok and .home == $home and .name == "Two"' <<<"$launch" >/dev/null
helper switch claude "$first_claude" >/dev/null
check test "$(sha256sum "$claude_home/.credentials.json" | cut -d' ' -f1)" = "$live_claude_hash"
check jq -e '.accounts[] | select(.name == "Two") | .credentials.refreshToken == "refresh-two-rotated"' \
  "$switcher_dir/claude-accounts.json" >/dev/null

# A stable Claude home may clear an expired access token while retaining the
# refresh token. It remains selectable and its refreshable state is retained.
jq '.claudeAiOauth.accessToken = ""' "$first_claude_home/.credentials.json" >"$fixture/refresh-only.json"
mv "$fixture/refresh-only.json" "$first_claude_home/.credentials.json"
chmod 600 "$first_claude_home/.credentials.json"
refresh_only_selection=$(helper switch claude "$first_claude")
check jq -e '.ok == true' <<<"$refresh_only_selection" >/dev/null
check jq -e --arg id "$first_claude" '.accounts[] | select(.id == $id) |
  .credentials.accessToken == "" and .credentials.refreshToken == "refresh-one"' \
  "$switcher_dir/claude-accounts.json" >/dev/null
check jq -e '.theme == "dark" and .oauthAccount.accountUuid == "uuid-one"' \
  "$first_claude_home/.claude.json" >/dev/null

write_claude two@example.com uuid-two two 'Two Org'
helper import-current claude Two >/dev/null
export FAKE_PS_OUTPUT='202 pts/2 claude claude --resume test'
selected=$(helper switch claude "$first_claude")
check jq -e '.ok and (.message | contains("new sessions"))' <<<"$selected" >/dev/null
check jq -e '.providers.claude.running_count == 1 and .providers.claude.can_switch == true' \
  <<<"$(helper status)" >/dev/null
unset FAKE_PS_OUTPUT

helper rename claude "$first_claude" Personal >/dev/null
check jq -e --arg id "$first_claude" '.accounts[] | select(.id == $id) | .name == "Personal"' \
  "$switcher_dir/claude-accounts.json" >/dev/null
helper remove claude "$first_claude" >/dev/null
check jq -e --arg id "$first_claude" '[.accounts[] | select(.id == $id)] | length == 0' \
  "$switcher_dir/claude-accounts.json" >/dev/null
check test ! -e "$first_claude_home"

# Two seats on one email share an email address and an accountUuid, so only the
# organization separates them. Each seat is saved and refreshed on its own.
reset_fixture claude-same-email-seats
write_claude seats@example.com uuid-one-person personal 'Personal' org-personal
helper import-current claude Personal >/dev/null
write_claude seats@example.com uuid-one-person team 'FITec Labs' org-team
helper import-current claude Team >/dev/null
check jq -e '.accounts | length == 2' "$switcher_dir/claude-accounts.json" >/dev/null
check jq -e '[.accounts[].credentials.refreshToken] | sort == ["refresh-personal","refresh-team"]' \
  "$switcher_dir/claude-accounts.json" >/dev/null
check jq -e '[.accounts[] | select(.name == "Personal")] | length == 1' \
  "$switcher_dir/claude-accounts.json" >/dev/null

# Re-importing a seat refreshes that seat alone and never forks a third entry.
write_claude seats@example.com uuid-one-person personal-rotated 'Personal' org-personal
helper import-current claude >/dev/null
check jq -e '.accounts | length == 2' "$switcher_dir/claude-accounts.json" >/dev/null
check jq -e '.accounts[] | select(.name == "Personal") |
  .credentials.refreshToken == "refresh-personal-rotated"' \
  "$switcher_dir/claude-accounts.json" >/dev/null
check jq -e '.accounts[] | select(.name == "Team") |
  .credentials.refreshToken == "refresh-team"' \
  "$switcher_dir/claude-accounts.json" >/dev/null

# Each seat keeps a private home, so neither can read the other's credentials.
personal_seat=$(jq -r '.accounts[] | select(.name == "Personal").id' \
  "$switcher_dir/claude-accounts.json")
team_seat=$(jq -r '.accounts[] | select(.name == "Team").id' \
  "$switcher_dir/claude-accounts.json")
check test "$personal_seat" != "$team_seat"
check jq -e '.claudeAiOauth.refreshToken == "refresh-personal-rotated"' \
  "$switcher_dir/homes/claude/$personal_seat/.credentials.json" >/dev/null
check jq -e '.claudeAiOauth.refreshToken == "refresh-team"' \
  "$switcher_dir/homes/claude/$team_seat/.credentials.json" >/dev/null

# A store written before organizations were recorded still matches on identity
# alone, so an existing account is refreshed rather than duplicated.
reset_fixture claude-legacy-store
write_claude legacy@example.com uuid-legacy legacy 'Legacy'
helper import-current claude Legacy >/dev/null
check jq -e '.accounts[0].oauth_account | has("organizationUuid") == false' \
  "$switcher_dir/claude-accounts.json" >/dev/null
write_claude legacy@example.com uuid-legacy legacy-rotated 'Legacy' org-legacy
helper import-current claude >/dev/null
check jq -e '.accounts | length == 1' "$switcher_dir/claude-accounts.json" >/dev/null
check jq -e '.accounts[0].credentials.refreshToken == "refresh-legacy-rotated"' \
  "$switcher_dir/claude-accounts.json" >/dev/null

# The account matching Claude's original shared profile adopts that profile's
# resumable history. Other accounts keep independent histories.
reset_fixture claude-shared-history
unset CLAUDE_CONFIG_DIR
shared_claude_home="$HOME/.claude"
mkdir -p "$shared_claude_home/projects/-shared-project"
jq -n '{claudeAiOauth:{
  accessToken:"shared-access",refreshToken:"shared-refresh",subscriptionType:"team"
},mcpOAuth:{example:{accessToken:"mcp-token"}}}' >"$shared_claude_home/.credentials.json"
jq -n '{oauthAccount:{
  emailAddress:"valiot@example.com",accountUuid:"uuid-valiot",organizationName:"Valiot"
},projects:{"/shared/project":{}}}' >"$HOME/.claude.json"
jq -cn '{display:"original",pastedContents:{},project:"/shared/project",
  sessionId:"session-original",timestamp:1}' >"$shared_claude_home/history.jsonl"
printf '{"type":"summary","sessionId":"session-original"}\n' \
  >"$shared_claude_home/projects/-shared-project/session-original.jsonl"

helper import-current claude Valiot >/dev/null
valiot_id=$(jq -r '.accounts[0].id' "$switcher_dir/claude-accounts.json")
valiot_home="$switcher_dir/homes/claude/$valiot_id"
check test -L "$valiot_home/history.jsonl"
check test "$(readlink -f "$valiot_home/history.jsonl")" = "$shared_claude_home/history.jsonl"
check test -L "$valiot_home/projects"
check test "$(readlink -f "$valiot_home/projects")" = "$shared_claude_home/projects"

# Simulate history written by a pre-fix isolated home, then verify migration
# merges it into the shared Valiot profile and retains a private backup.
rm -- "$valiot_home/history.jsonl" "$valiot_home/projects"
mkdir -p "$valiot_home/projects/-isolated-project"
jq -cn '{display:"isolated",pastedContents:{},project:"/isolated/project",
  sessionId:"session-isolated",timestamp:2}' >"$valiot_home/history.jsonl"
jq -cn '{display:"original",pastedContents:{},project:"/shared/project",
  sessionId:"session-original",timestamp:1}' >>"$valiot_home/history.jsonl"
printf '{"type":"summary","sessionId":"session-isolated"}\n' \
  >"$valiot_home/projects/-isolated-project/session-isolated.jsonl"
helper prepare-launch claude "$valiot_id" >/dev/null
check test "$(jq -s 'length' "$shared_claude_home/history.jsonl")" = 2
check test -f "$shared_claude_home/projects/-shared-project/session-original.jsonl"
check test -f "$shared_claude_home/projects/-isolated-project/session-isolated.jsonl"
check test -n "$(find "$switcher_dir/history-backups/claude/$valiot_id" -type f -name history.jsonl -print -quit)"
backup_count=$(find "$switcher_dir/history-backups/claude/$valiot_id" -type f | wc -l)
helper prepare-launch claude "$valiot_id" >/dev/null
check test "$(jq -s 'length' "$shared_claude_home/history.jsonl")" = 2
check test "$(find "$switcher_dir/history-backups/claude/$valiot_id" -type f | wc -l)" = "$backup_count"

other_claude_home="$fixture/other-claude"
mkdir -p "$other_claude_home"
claude_home="$other_claude_home"
write_claude omarchy@example.com uuid-omarchy omarchy 'Omacom'
CLAUDE_CONFIG_DIR="$other_claude_home" helper import-current claude Omarchy --inactive >/dev/null
omarchy_id=$(jq -r '.accounts[] | select(.name == "Omarchy").id' "$switcher_dir/claude-accounts.json")
omarchy_home="$switcher_dir/homes/claude/$omarchy_id"
check test ! -L "$omarchy_home/history.jsonl"
check test ! -L "$omarchy_home/projects"

printf 'Account helper tests passed (%d checks)\n' "$checks"
