#!/bin/bash

set -Eeu -o pipefail

CONFIG_DIR="${OMARCHY_AI_SWITCHER_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/ai-account-switcher}"
HOMES_DIR="$CONFIG_DIR/homes"

fail() {
  jq -cn --arg error "$1" '{ok: false, error: $error}'
  exit 1
}

utc_now() {
  date -u +'%Y-%m-%dT%H:%M:%S.%NZ'
}

new_id() {
  tr -d '\n' </proc/sys/kernel/random/uuid
}

provider_store() {
  case $1 in
    codex) printf '%s/codex-accounts.json\n' "$CONFIG_DIR" ;;
    claude) printf '%s/claude-accounts.json\n' "$CONFIG_DIR" ;;
    *) fail "Unknown provider: $1" ;;
  esac
}

provider_source_home() {
  case $1 in
    codex) printf '%s\n' "${OMARCHY_AI_SOURCE_CODEX_HOME:-${CODEX_HOME:-$HOME/.codex}}" ;;
    claude) printf '%s\n' "${OMARCHY_AI_SOURCE_CLAUDE_CONFIG_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}" ;;
    *) fail "Unknown provider: $1" ;;
  esac
}

validate_account_id() {
  [[ $1 =~ ^[A-Za-z0-9_-]+$ ]] || fail "Invalid account id"
}

account_home() {
  local provider=$1 account_id=$2
  validate_account_id "$account_id"
  printf '%s/%s/%s\n' "$HOMES_DIR" "$provider" "$account_id"
}

ensure_private_directory() {
  local path=$1
  if [[ -L $path || ( -e $path && ! -d $path ) ]]; then
    fail "Refusing unsafe account home: $path"
  fi
  mkdir -p -- "$path"
  chmod 700 -- "$path"
}

link_shared_config() {
  local provider=$1 home=$2 source entry target
  source=$(provider_source_home "$provider")
  case $provider in
    codex)
      for entry in AGENTS.md agents config.toml hooks.json memories plugins rules skills; do
        target="$home/$entry"
        if [[ ( -e $source/$entry || -L $source/$entry ) && ! -e $target && ! -L $target ]]; then
          ln -s -- "$source/$entry" "$target"
        fi
      done
      ;;
    claude)
      for entry in CLAUDE.md hooks plugins settings.json skills themes; do
        target="$home/$entry"
        if [[ ( -e $source/$entry || -L $source/$entry ) && ! -e $target && ! -L $target ]]; then
          ln -s -- "$source/$entry" "$target"
        fi
      done
      ;;
  esac
}

load_store() {
  local path=$1
  if [[ ! -e $path ]]; then
    STORE_JSON='{"version":2,"accounts":[],"active_account_id":null}'
    return
  fi
  if [[ -L $path ]]; then fail "Refusing to read symlink: $path"; fi
  if ! STORE_JSON=$(jq -c '
    if type != "object" or (.accounts | type) != "array" then
      error("invalid account store")
    else
      .version = 2 | .active_account_id //= null
    end
  ' "$path" 2>/dev/null); then
    fail "Could not read $(basename "$path")"
  fi
}

lock_store() {
  if [[ -L $CONFIG_DIR || ( -e $CONFIG_DIR && ! -d $CONFIG_DIR ) ]]; then
    fail "Refusing unsafe config directory: $CONFIG_DIR"
  fi
  mkdir -p -- "$CONFIG_DIR"
  chmod 700 -- "$CONFIG_DIR"
  exec 9>"$CONFIG_DIR/.lock"
  chmod 600 -- "$CONFIG_DIR/.lock"
  flock -x 9
}

atomic_private_write() {
  local path=$1 value=$2 directory temporary
  directory=$(dirname -- "$path")
  mkdir -p -- "$directory"
  chmod 700 -- "$directory"
  if [[ -L $path ]]; then fail "Refusing to replace symlink: $path"; fi
  temporary=$(mktemp "$directory/.$(basename "$path").XXXXXX")
  chmod 600 -- "$temporary"
  if ! printf '%s\n' "$value" | jq . >"$temporary"; then
    rm -f -- "$temporary"
    fail "Could not write $(basename "$path")"
  fi
  mv -fT -- "$temporary" "$path"
  chmod 600 -- "$path"
}

atomic_preserving_write() {
  local path=$1 value=$2 directory temporary mode=600
  directory=$(dirname -- "$path")
  mkdir -p -- "$directory"
  if [[ -L $path ]]; then fail "Refusing to replace symlink: $path"; fi
  if [[ -e $path ]]; then mode=$(stat -c '%a' -- "$path"); fi
  temporary=$(mktemp "$directory/.$(basename "$path").XXXXXX")
  chmod "$mode" -- "$temporary"
  if ! printf '%s\n' "$value" | jq . >"$temporary"; then
    rm -f -- "$temporary"
    fail "Could not write $(basename "$path")"
  fi
  mv -fT -- "$temporary" "$path"
  chmod "$mode" -- "$path"
}

jwt_claims() {
  local token=$1 payload padding
  if [[ $token != *.*.* ]]; then printf '{}\n'; return; fi
  payload=${token#*.}
  payload=${payload%%.*}
  payload=${payload//-/+}
  payload=${payload//_/\/}
  padding=$(( (4 - ${#payload} % 4) % 4 ))
  while (( padding-- > 0 )); do payload+='='; done
  if ! printf '%s' "$payload" | base64 -d 2>/dev/null | jq -c \
    'if type == "object" then . else {} end' 2>/dev/null; then
    printf '{}\n'
  fi
}

codex_auth_path() {
  printf '%s/auth.json\n' "${CODEX_HOME:-$HOME/.codex}"
}

claude_credentials_path() {
  printf '%s/.credentials.json\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
}

claude_state_path() {
  if [[ -n ${CLAUDE_CONFIG_DIR:-} ]]; then
    printf '%s/.claude.json\n' "$CLAUDE_CONFIG_DIR"
  else
    printf '%s/.claude.json\n' "$HOME"
  fi
}

codex_current_account() {
  local path auth mode id created token claims email plan account_id suffix name auth_data
  path=$(codex_auth_path)
  if [[ ! -f $path || -L $path ]]; then printf 'null\n'; return; fi
  if ! auth=$(jq -c 'if type == "object" then . else error("invalid") end' "$path" 2>/dev/null); then
    printf 'null\n'; return
  fi
  id=$(new_id)
  created=$(utc_now)
  mode=$(printf '%s' "$auth" | jq -r '
    if (.OPENAI_API_KEY | type) == "string" and .OPENAI_API_KEY != "" then "api_key"
    elif (.tokens | type) == "object" and
      ([.tokens.id_token, .tokens.access_token, .tokens.refresh_token] | all(type == "string" and . != ""))
    then "chatgpt" else "" end')

  if [[ $mode == api_key ]]; then
    printf '%s' "$auth" | jq -c --arg id "$id" --arg created "$created" '{
      id: $id,
      name: "API key account",
      email: null,
      plan_type: null,
      subscription_expires_at: null,
      auth_mode: "api_key",
      auth_data: {type: "api_key", key: .OPENAI_API_KEY},
      created_at: $created,
      last_used_at: null
    }'
    return
  fi
  if [[ $mode != chatgpt ]]; then printf 'null\n'; return; fi

  token=$(printf '%s' "$auth" | jq -r '.tokens.id_token')
  claims=$(jwt_claims "$token")
  email=$(printf '%s' "$claims" | jq -r '.email // empty')
  plan=$(printf '%s' "$claims" | jq -r '.["https://api.openai.com/auth"].chatgpt_plan_type // empty')
  account_id=$(printf '%s' "$claims" | jq -r '.["https://api.openai.com/auth"].chatgpt_account_id // empty')
  if [[ -z $account_id ]]; then account_id=$(printf '%s' "$auth" | jq -r '.tokens.account_id // empty'); fi
  suffix=${account_id: -8}
  name=${email:-${suffix:+ChatGPT account ($suffix)}}
  name=${name:-ChatGPT account}
  auth_data=$(printf '%s' "$auth" | jq -c '{
    type: "chatgpt",
    id_token: .tokens.id_token,
    access_token: .tokens.access_token,
    refresh_token: .tokens.refresh_token,
    account_id: (.tokens.account_id // null)
  }')
  printf '%s' "$auth_data" | jq -c \
    --arg id "$id" --arg name "$name" --arg email "$email" --arg plan "$plan" \
    --arg account_id "$account_id" --arg created "$created" '{
      id: $id,
      name: $name,
      email: (if $email == "" then null else $email end),
      plan_type: (if $plan == "" then null else $plan end),
      subscription_expires_at: null,
      auth_mode: "chatgpt",
      auth_data: (. + {account_id: (if $account_id == "" then .account_id else $account_id end)}),
      created_at: $created,
      last_used_at: null
    }'
}

claude_auth_status() {
  if ! command -v claude >/dev/null 2>&1; then printf '{}\n'; return; fi
  local value
  if value=$(timeout 15 claude auth status --json 2>/dev/null) &&
    printf '%s' "$value" | jq -e 'type == "object"' >/dev/null 2>&1; then
    printf '%s' "$value" | jq -c .
  else
    printf '{}\n'
  fi
}

claude_current_account() {
  local query_status=${1:-false} credentials_path state_path credentials state status
  local id created email org subscription account_uuid suffix name
  credentials_path=$(claude_credentials_path)
  state_path=$(claude_state_path)
  if [[ ! -f $credentials_path || -L $credentials_path ]]; then printf 'null\n'; return; fi
  if ! credentials=$(jq -c '
    if type == "object" and (.claudeAiOauth | type) == "object" and
      (((.claudeAiOauth.accessToken | type) == "string" and .claudeAiOauth.accessToken != "") or
       ((.claudeAiOauth.refreshToken | type) == "string" and .claudeAiOauth.refreshToken != ""))
    then . else error("invalid") end
  ' "$credentials_path" 2>/dev/null); then
    printf 'null\n'; return
  fi
  if [[ -f $state_path && ! -L $state_path ]]; then
    state=$(jq -c 'if type == "object" then . else {} end' "$state_path" 2>/dev/null || printf '{}')
  else
    state='{}'
  fi
  email=$(printf '%s' "$state" | jq -r '.oauthAccount.emailAddress // empty')
  if [[ $query_status == true || -z $email ]]; then status=$(claude_auth_status); else status='{}'; fi
  email=${email:-$(printf '%s' "$status" | jq -r '.email // empty')}
  org=$(printf '%s' "$state" | jq -r '.oauthAccount.organizationName // empty')
  org=${org:-$(printf '%s' "$status" | jq -r '.orgName // empty')}
  subscription=$(printf '%s' "$status" | jq -r '.subscriptionType // empty')
  if [[ -z $subscription ]]; then
    subscription=$(printf '%s' "$credentials" | jq -r '.claudeAiOauth.subscriptionType // empty')
  fi
  if [[ -z $subscription ]]; then subscription=$(printf '%s' "$state" | jq -r '.oauthAccount.seatTier // empty'); fi
  account_uuid=$(printf '%s' "$state" | jq -r '.oauthAccount.accountUuid // empty')
  suffix=${account_uuid: -8}
  name=${email:-${suffix:+Claude account ($suffix)}}
  name=${name:-Claude account}
  id=$(new_id)
  created=$(utc_now)
  printf '%s' "$credentials" | jq -c --slurpfile state <(printf '%s\n' "$state") \
    --arg id "$id" --arg name "$name" --arg email "$email" --arg org "$org" \
    --arg subscription "$subscription" --arg created "$created" '{
      id: $id,
      name: $name,
      email: (if $email == "" then null else $email end),
      org_name: (if $org == "" then null else $org end),
      subscription_type: (if $subscription == "" then null else $subscription end),
      credentials: .claudeAiOauth,
      oauth_account: (if ($state[0].oauthAccount | type) == "object" then $state[0].oauthAccount else null end),
      created_at: $created,
      last_used_at: null
    }'
}

codex_match_index() {
  local candidate=$1
  printf '%s' "$STORE_JSON" | jq -r --slurpfile candidate <(printf '%s\n' "$candidate") '
    ($candidate[0]) as $c |
    [.accounts | to_entries[] | select(
      if $c.auth_mode == "api_key" then
        .value.auth_mode == "api_key" and .value.auth_data.key == $c.auth_data.key
      elif ($c.auth_data.account_id // "") != "" then
        .value.auth_data.account_id == $c.auth_data.account_id
      elif ($c.email // "") != "" then
        ((.value.email // "") | ascii_downcase) == (($c.email // "") | ascii_downcase)
      else
        .value.auth_data.refresh_token == $c.auth_data.refresh_token
      end
    )] | first | (.key // -1)
  '
}

claude_match_index() {
  local candidate=$1
  printf '%s' "$STORE_JSON" | jq -r --slurpfile candidate <(printf '%s\n' "$candidate") '
    # Two seats on one email share an accountUuid and an emailAddress, so the
    # organization is what separates them. Compare it only when both sides know
    # it, so accounts saved before it was recorded still match on identity alone.
    def org_conflict($a; $b): ($a // "") != "" and ($b // "") != "" and $a != $b;
    ($candidate[0]) as $c |
    [.accounts | to_entries[] | select(
      (org_conflict(.value.oauth_account.organizationUuid; $c.oauth_account.organizationUuid) | not)
      and (
        if ($c.oauth_account.accountUuid // "") != "" then
          .value.oauth_account.accountUuid == $c.oauth_account.accountUuid
        elif ($c.email // "") != "" then
          ((.value.email // "") | ascii_downcase) == (($c.email // "") | ascii_downcase)
        else
          .value.credentials.refreshToken == $c.credentials.refreshToken
        end
      )
    )] | first | (.key // -1)
  '
}

provider_current_account() {
  case $1 in
    codex) codex_current_account ;;
    claude) claude_current_account "${2:-false}" ;;
  esac
}

provider_match_index() {
  case $1 in
    codex) codex_match_index "$2" ;;
    claude) claude_match_index "$2" ;;
  esac
}

running_processes() {
  local provider=$1
  ps -axo pid=,tty=,comm=,args= | awk -v provider="$provider" '
    {
      pid=$1; tty=$2; comm=$3
      $1=$2=$3=""; sub(/^[[:space:]]+/, "", $0); args=$0
      split(args, words, /[[:space:]]+/)
      first=words[1]; sub(/^.*\//, "", first)
      command=comm; sub(/^.*\//, "", command)
      if (tty == "?" || tty == "??" || tty == "-") next
      if (provider == "codex") {
        lowered=tolower(args)
        if ((command == "codex" || first == "codex") &&
            lowered !~ /codex app-server/ && lowered !~ /codex-code-mode-host/) print pid
      } else if (provider == "claude" && (command == "claude" || first == "claude")) {
        print pid
      }
    }
  '
}

running_count() {
  running_processes "$1" | awk 'NF { count++ } END { print count + 0 }'
}

provider_status() {
  local provider=$1 store_path current index current_id active_id count has_current suggested
  store_path=$(provider_store "$provider")
  load_store "$store_path"
  current=$(provider_current_account "$provider" false)
  current_id=''
  if [[ $current != null ]]; then
    index=$(provider_match_index "$provider" "$current")
    if (( index >= 0 )); then current_id=$(printf '%s' "$STORE_JSON" | jq -r --argjson index "$index" '.accounts[$index].id'); fi
  fi
  active_id=$(printf '%s' "$STORE_JSON" | jq -r '.active_account_id // empty')
  if [[ -z $active_id ]]; then active_id=$current_id; fi
  count=$(running_count "$provider")
  if [[ $current == null ]]; then has_current=false; suggested=''; else has_current=true; suggested=$(printf '%s' "$current" | jq -r '.name // empty'); fi

  if [[ $provider == codex ]]; then
    printf '%s' "$STORE_JSON" | jq -c \
      --arg active "$active_id" --arg current "$current_id" --arg suggested "$suggested" \
      --argjson has_current "$has_current" --argjson count "$count" '{
        ok: true, provider: "codex",
        accounts: [.accounts[] | {
          id: (.id | tostring), name: (.name // "Account"), email, plan_type, auth_mode,
          is_active: (.id == $active), is_current: (.id == $current), last_used_at
        }],
        active_account_id: (if $active == "" then null else $active end),
        current_saved: ($current != ""), has_current_login: $has_current,
        suggested_name: $suggested, can_switch: true, running_count: $count
      }'
  else
    printf '%s' "$STORE_JSON" | jq -c \
      --arg active "$active_id" --arg current "$current_id" --arg suggested "$suggested" \
      --argjson has_current "$has_current" --argjson count "$count" '{
        ok: true, provider: "claude",
        accounts: [.accounts[] | {
          id: (.id | tostring), name: (.name // "Account"), email, org_name, subscription_type,
          is_active: (.id == $active), is_current: (.id == $current), last_used_at
        }],
        active_account_id: (if $active == "" then null else $active end),
        current_saved: ($current != ""), has_current_login: $has_current,
        suggested_name: $suggested, can_switch: true, running_count: $count
      }'
  fi
}

combined_status() {
  local codex claude wrappers=false marker='omarchy-ai-account-switcher command router v1'
  local wrapper_bin="${OMARCHY_AI_SWITCHER_BIN_DIR:-$HOME/.local/bin}"
  local mise_marker='omarchy-ai-account-switcher mise aliases v1'
  local mise_conf_dir="${OMARCHY_AI_SWITCHER_MISE_CONF_DIR:-${MISE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/mise}/conf.d}"
  local mise_fragment="$mise_conf_dir/omarchy-ai-account-switcher.toml"
  codex=$(provider_status codex)
  claude=$(provider_status claude)
  if [[ -f $wrapper_bin/codex && ! -L $wrapper_bin/codex &&
    -f $wrapper_bin/claude && ! -L $wrapper_bin/claude ]] &&
    grep -Fq "$marker" "$wrapper_bin/codex" 2>/dev/null &&
    grep -Fq "$marker" "$wrapper_bin/claude" 2>/dev/null &&
    [[ -f $mise_fragment && ! -L $mise_fragment ]] &&
    grep -Fq "$mise_marker" "$mise_fragment" 2>/dev/null; then
    wrappers=true
  fi
  jq -cn --slurpfile codex <(printf '%s\n' "$codex") --slurpfile claude <(printf '%s\n' "$claude") \
    --argjson wrappers "$wrappers" \
    '{ok: true, command_wrappers_enabled: $wrappers, providers: {codex: $codex[0], claude: $claude[0]}}'
}

import_current() {
  local provider=$1 name=$2 activate=$3 store_path candidate index saved_id saved_name
  local previous_active existing_id existing_name existing_created existing_last
  store_path=$(provider_store "$provider")
  lock_store
  load_store "$store_path"
  previous_active=$(printf '%s' "$STORE_JSON" | jq -r '.active_account_id // empty')
  candidate=$(provider_current_account "$provider" true)
  if [[ $candidate == null ]]; then fail "No ${provider^} login is available to save"; fi
  index=$(provider_match_index "$provider" "$candidate")

  if (( index >= 0 )); then
    existing_id=$(printf '%s' "$STORE_JSON" | jq -r --argjson index "$index" '.accounts[$index].id')
    existing_name=$(printf '%s' "$STORE_JSON" | jq -r --argjson index "$index" '.accounts[$index].name // empty')
    existing_created=$(printf '%s' "$STORE_JSON" | jq -r --argjson index "$index" '.accounts[$index].created_at // empty')
    existing_last=$(printf '%s' "$STORE_JSON" | jq -c --argjson index "$index" '.accounts[$index].last_used_at // null')
    saved_name=${name:-$existing_name}
    saved_name=${saved_name:-$(printf '%s' "$candidate" | jq -r '.name')}
    candidate=$(printf '%s' "$candidate" | jq -c \
      --arg id "$existing_id" --arg name "$saved_name" --arg created "$existing_created" \
      --argjson last "$existing_last" '.id=$id | .name=$name | .created_at=$created | .last_used_at=$last')
    STORE_JSON=$(printf '%s' "$STORE_JSON" | jq -c --argjson index "$index" \
      --slurpfile candidate <(printf '%s\n' "$candidate") '.accounts[$index]=$candidate[0]')
  else
    if [[ -n $name ]]; then candidate=$(printf '%s' "$candidate" | jq -c --arg name "$name" '.name=$name'); fi
    STORE_JSON=$(printf '%s' "$STORE_JSON" | jq -c --slurpfile candidate <(printf '%s\n' "$candidate") \
      '.accounts += [$candidate[0]]')
  fi
  saved_id=$(printf '%s' "$candidate" | jq -r '.id')
  saved_name=$(printf '%s' "$candidate" | jq -r '.name')
  if [[ $activate == true ]]; then
    STORE_JSON=$(printf '%s' "$STORE_JSON" | jq -c --arg id "$saved_id" '.active_account_id=$id')
  else
    STORE_JSON=$(printf '%s' "$STORE_JSON" | jq -c --arg id "$previous_active" \
      '.active_account_id=(if $id == "" then null else $id end)')
  fi
  materialize_account_home "$provider" "$candidate" true >/dev/null
  atomic_private_write "$store_path" "$STORE_JSON"
  jq -cn --arg message "Saved $saved_name" '{ok: true, message: $message}'
}

write_codex_account() {
  local destination=${1:-} account auth path
  account=$(cat)
  path=${destination:-$(codex_auth_path)}
  if [[ $(printf '%s' "$account" | jq -r '.auth_mode') == api_key ]]; then
    auth=$(printf '%s' "$account" | jq -c '{auth_mode:"api_key",OPENAI_API_KEY:.auth_data.key}')
  else
    auth=$(printf '%s' "$account" | jq -c --arg now "$(utc_now)" '{
      auth_mode: "chatgpt", OPENAI_API_KEY: null,
      tokens: ({
        id_token: .auth_data.id_token,
        access_token: .auth_data.access_token,
        refresh_token: .auth_data.refresh_token
      } + (if (.auth_data.account_id // "") == "" then {} else {account_id:.auth_data.account_id} end)),
      last_refresh: $now
    }')
  fi
  atomic_private_write "$path" "$auth"
}

write_claude_account() {
  local destination_home=${1:-} account credentials_path state_path credentials_document state oauth_type
  account=$(cat)
  if [[ -n $destination_home ]]; then
    credentials_path="$destination_home/.credentials.json"
    state_path="$destination_home/.claude.json"
  else
    credentials_path=$(claude_credentials_path)
    state_path=$(claude_state_path)
  fi
  if [[ -f $credentials_path && ! -L $credentials_path ]]; then
    credentials_document=$(jq -c 'if type == "object" then . else {} end' "$credentials_path" 2>/dev/null || printf '{}')
  else
    credentials_document='{}'
  fi
  credentials_document=$(printf '%s' "$credentials_document" | jq -c \
    --slurpfile account <(printf '%s\n' "$account") '.claudeAiOauth=$account[0].credentials')
  atomic_preserving_write "$credentials_path" "$credentials_document"

  oauth_type=$(printf '%s' "$account" | jq -r '.oauth_account | type')
  [[ $oauth_type == object ]] || return 0
  if [[ -f $state_path && ! -L $state_path ]]; then
    state=$(jq -c 'if type == "object" then . else {} end' "$state_path" 2>/dev/null || printf '{}')
  else
    state='{}'
  fi
  state=$(printf '%s' "$state" | jq -c --slurpfile account <(printf '%s\n' "$account") \
    '.oauthAccount=$account[0].oauth_account')
  atomic_preserving_write "$state_path" "$state"
}

seed_claude_credentials() {
  local home=$1 source credentials target
  target="$home/.credentials.json"
  [[ -e $target || -L $target ]] && return 0
  source="$(provider_source_home claude)/.credentials.json"
  [[ -f $source && ! -L $source ]] || return 0
  credentials=$(jq -c 'if type == "object" then . else {} end' "$source" 2>/dev/null || printf '{}')
  atomic_private_write "$target" "$credentials"
}

seed_claude_state() {
  local home=$1 source state target
  target="$home/.claude.json"
  [[ -e $target || -L $target ]] && return 0
  if [[ -n ${OMARCHY_AI_SOURCE_CLAUDE_STATE:-} ]]; then
    source="$OMARCHY_AI_SOURCE_CLAUDE_STATE"
  elif [[ -n ${OMARCHY_AI_SOURCE_CLAUDE_CONFIG_DIR:-} ]]; then
    source="$OMARCHY_AI_SOURCE_CLAUDE_CONFIG_DIR/.claude.json"
  elif [[ -n ${CLAUDE_CONFIG_DIR:-} ]]; then
    source="$CLAUDE_CONFIG_DIR/.claude.json"
  else
    source="$HOME/.claude.json"
  fi
  [[ -f $source && ! -L $source ]] || return 0
  state=$(jq -c 'if type == "object" then . else {} end' "$source" 2>/dev/null || printf '{}')
  atomic_private_write "$target" "$state"
}

shared_claude_history_home() {
  printf '%s\n' "${OMARCHY_AI_SHARED_CLAUDE_HOME:-$HOME/.claude}"
}

shared_claude_state_path() {
  printf '%s\n' "${OMARCHY_AI_SHARED_CLAUDE_STATE:-$HOME/.claude.json}"
}

claude_account_owns_shared_history() {
  local account=$1 state_path state account_uuid shared_uuid account_email shared_email
  local account_org shared_org
  state_path=$(shared_claude_state_path)
  [[ -f $state_path && ! -L $state_path ]] || return 1
  state=$(jq -c 'if type == "object" then . else {} end' "$state_path" 2>/dev/null || printf '{}')
  # Only the seat the shared profile was logged into owns its history. Seats
  # sharing an email are told apart by organization, so when both sides record
  # one it must agree before any identity check can claim ownership.
  account_org=$(printf '%s' "$account" | jq -r '.oauth_account.organizationUuid // empty')
  shared_org=$(printf '%s' "$state" | jq -r '.oauthAccount.organizationUuid // empty')
  if [[ -n $account_org && -n $shared_org && $account_org != "$shared_org" ]]; then return 1; fi
  account_uuid=$(printf '%s' "$account" | jq -r '.oauth_account.accountUuid // empty')
  shared_uuid=$(printf '%s' "$state" | jq -r '.oauthAccount.accountUuid // empty')
  if [[ -n $account_uuid && -n $shared_uuid ]]; then [[ $account_uuid == "$shared_uuid" ]]; return; fi
  account_email=$(printf '%s' "$account" | jq -r '.email // empty' | tr '[:upper:]' '[:lower:]')
  shared_email=$(printf '%s' "$state" | jq -r '.oauthAccount.emailAddress // empty' | tr '[:upper:]' '[:lower:]')
  [[ -n $account_email && -n $shared_email && $account_email == "$shared_email" ]]
}

ensure_shared_history_target() {
  local target=$1 kind=$2
  [[ ! -L $target ]] || fail "Refusing unsafe shared Claude history path: $target"
  case $kind in
    file)
      if [[ -e $target && ! -f $target ]]; then fail "Refusing unsafe shared Claude history file: $target"; fi
      if [[ ! -e $target ]]; then
        mkdir -p -- "$(dirname -- "$target")"
        : >"$target"
        chmod 600 -- "$target"
      fi
      ;;
    directory)
      ensure_private_directory "$target"
      ;;
  esac
}

merge_claude_history_file() {
  local source=$1 destination=$2 missing
  [[ -f $source && ! -L $source ]] || return 0
  if ! missing=$(jq -c --slurpfile existing "$destination" '
    . as $entry |
    select(any($existing[];
      .sessionId == $entry.sessionId and
      .timestamp == $entry.timestamp and
      .display == $entry.display) | not)
  ' "$source" 2>/dev/null); then
    fail "Could not merge saved Claude prompt history"
  fi
  if [[ -n $missing ]]; then printf '%s\n' "$missing" >>"$destination"; fi
  chmod 600 -- "$destination"
}

link_shared_claude_history() {
  local account=$1 home=$2 id shared_home backup_root timestamp source target resolved
  claude_account_owns_shared_history "$account" || return 0
  id=$(printf '%s' "$account" | jq -r '.id')
  shared_home=$(shared_claude_history_home)
  [[ $home != "$shared_home" ]] || return 0
  ensure_private_directory "$shared_home"
  timestamp=$(date -u +'%Y%m%dT%H%M%S.%NZ')
  backup_root="$CONFIG_DIR/history-backups/claude/$id/$timestamp"

  source="$home/history.jsonl"
  target="$shared_home/history.jsonl"
  if [[ -L $source ]]; then
    resolved=$(readlink -f -- "$source" 2>/dev/null || true)
    [[ $resolved == "$(readlink -f -- "$target" 2>/dev/null || printf '%s' "$target")" ]] ||
      fail "Refusing unexpected Claude history link: $source"
  else
    ensure_shared_history_target "$target" file
    if [[ -e $source ]]; then
      [[ -f $source ]] || fail "Refusing unsafe Claude history file: $source"
      merge_claude_history_file "$source" "$target"
      ensure_private_directory "$backup_root"
      mv -- "$source" "$backup_root/history.jsonl"
    fi
    ln -s -- "$target" "$source"
  fi

  source="$home/projects"
  target="$shared_home/projects"
  if [[ -L $source ]]; then
    resolved=$(readlink -f -- "$source" 2>/dev/null || true)
    [[ $resolved == "$(readlink -f -- "$target" 2>/dev/null || printf '%s' "$target")" ]] ||
      fail "Refusing unexpected Claude projects link: $source"
  else
    ensure_shared_history_target "$target" directory
    if [[ -e $source ]]; then
      [[ -d $source ]] || fail "Refusing unsafe Claude projects directory: $source"
      cp -a -n -- "$source/." "$target/"
      ensure_private_directory "$backup_root"
      mv -- "$source" "$backup_root/projects"
    fi
    ln -s -- "$target" "$source"
  fi
}

materialize_account_home() {
  local provider=$1 account=$2 force=${3:-false} id home credential had_credential=false
  id=$(printf '%s' "$account" | jq -r '.id')
  home=$(account_home "$provider" "$id")
  ensure_private_directory "$CONFIG_DIR"
  ensure_private_directory "$HOMES_DIR"
  ensure_private_directory "$HOMES_DIR/$provider"
  ensure_private_directory "$home"
  link_shared_config "$provider" "$home"

  if [[ $provider == codex ]]; then
    credential="$home/auth.json"
    if [[ $force == true || ! -e $credential ]]; then
      [[ ! -L $credential ]] || fail "Refusing to replace symlink: $credential"
      printf '%s' "$account" | write_codex_account "$credential"
    fi
  else
    credential="$home/.credentials.json"
    if [[ -e $credential ]]; then had_credential=true; fi
    seed_claude_credentials "$home"
    seed_claude_state "$home"
    link_shared_claude_history "$account" "$home"
    if [[ $force == true || $had_credential == false ]]; then
      [[ ! -L $credential ]] || fail "Refusing to replace symlink: $credential"
      printf '%s' "$account" | write_claude_account "$home"
    fi
  fi
  printf '%s\n' "$home"
}

sync_account_home_into_store() {
  local provider=$1 account_id=$2 home current index existing_name existing_created existing_last
  home=$(account_home "$provider" "$account_id")
  if [[ $provider == codex ]]; then
    [[ -f $home/auth.json && ! -L $home/auth.json ]] || return 0
    current=$(CODEX_HOME="$home" codex_current_account)
  else
    [[ -f $home/.credentials.json && ! -L $home/.credentials.json ]] || return 0
    current=$(CLAUDE_CONFIG_DIR="$home" claude_current_account false)
  fi
  [[ $current != null ]] || return 0
  index=$(printf '%s' "$STORE_JSON" | jq -r --arg id "$account_id" \
    '[.accounts | to_entries[] | select(.value.id == $id)] | first | (.key // -1)')
  (( index >= 0 )) || return 0
  existing_name=$(printf '%s' "$STORE_JSON" | jq -r --argjson index "$index" '.accounts[$index].name')
  existing_created=$(printf '%s' "$STORE_JSON" | jq -r --argjson index "$index" '.accounts[$index].created_at')
  existing_last=$(printf '%s' "$STORE_JSON" | jq -c --argjson index "$index" '.accounts[$index].last_used_at // null')
  current=$(printf '%s' "$current" | jq -c \
    --arg id "$account_id" --arg name "$existing_name" --arg created "$existing_created" \
    --argjson last "$existing_last" '.id=$id | .name=$name | .created_at=$created | .last_used_at=$last')
  STORE_JSON=$(printf '%s' "$STORE_JSON" | jq -c --argjson index "$index" \
    --slurpfile current <(printf '%s\n' "$current") '.accounts[$index]=$current[0]')
}

switch_account() {
  local provider=$1 account_id=$2 store_path target now name
  store_path=$(provider_store "$provider")
  lock_store
  load_store "$store_path"
  target=$(printf '%s' "$STORE_JSON" | jq -c --arg id "$account_id" '.accounts[] | select(.id == $id)' | head -n 1)
  [[ -n $target ]] || fail "Account not found"
  materialize_account_home "$provider" "$target" false >/dev/null
  sync_account_home_into_store "$provider" "$account_id"
  now=$(utc_now)
  STORE_JSON=$(printf '%s' "$STORE_JSON" | jq -c --arg id "$account_id" --arg now "$now" '
    .active_account_id=$id | .accounts |= map(if .id == $id then .last_used_at=$now else . end)')
  atomic_private_write "$store_path" "$STORE_JSON"
  name=$(printf '%s' "$target" | jq -r '.name')
  jq -cn --arg message "Selected $name for new sessions" '{ok: true, message: $message}'
}

prepare_launch() {
  local provider=$1 account_id=${2:-} store_path target home now name
  store_path=$(provider_store "$provider")
  lock_store
  load_store "$store_path"
  if [[ -z $account_id ]]; then account_id=$(printf '%s' "$STORE_JSON" | jq -r '.active_account_id // empty'); fi
  [[ -n $account_id ]] || fail "Select a saved ${provider^} account first"
  target=$(printf '%s' "$STORE_JSON" | jq -c --arg id "$account_id" '.accounts[] | select(.id == $id)' | head -n 1)
  [[ -n $target ]] || fail "Account not found"
  home=$(materialize_account_home "$provider" "$target" false)
  sync_account_home_into_store "$provider" "$account_id"
  now=$(utc_now)
  STORE_JSON=$(printf '%s' "$STORE_JSON" | jq -c --arg id "$account_id" --arg now "$now" '
    .active_account_id=$id | .accounts |= map(if .id == $id then .last_used_at=$now else . end)')
  atomic_private_write "$store_path" "$STORE_JSON"
  name=$(printf '%s' "$STORE_JSON" | jq -r --arg id "$account_id" '.accounts[] | select(.id == $id) | .name')
  jq -cn --arg provider "$provider" --arg id "$account_id" --arg name "$name" --arg home "$home" \
    '{ok: true, provider: $provider, account_id: $id, name: $name, home: $home}'
}

rename_account() {
  local provider=$1 account_id=$2 name=$3 store_path count
  [[ -n ${name//[[:space:]]/} ]] || fail "Account name cannot be empty"
  store_path=$(provider_store "$provider")
  lock_store
  load_store "$store_path"
  count=$(printf '%s' "$STORE_JSON" | jq -r --arg id "$account_id" '[.accounts[] | select(.id == $id)] | length')
  (( count > 0 )) || fail "Account not found"
  STORE_JSON=$(printf '%s' "$STORE_JSON" | jq -c --arg id "$account_id" --arg name "$name" \
    '.accounts |= map(if .id == $id then .name=$name else . end)')
  atomic_private_write "$store_path" "$STORE_JSON"
  jq -cn --arg message "Renamed account to $name" '{ok: true, message: $message}'
}

remove_account() {
  local provider=$1 account_id=$2 store_path before after home
  store_path=$(provider_store "$provider")
  lock_store
  load_store "$store_path"
  before=$(printf '%s' "$STORE_JSON" | jq '.accounts | length')
  STORE_JSON=$(printf '%s' "$STORE_JSON" | jq -c --arg id "$account_id" '
    .accounts |= map(select(.id != $id)) |
    if .active_account_id == $id then .active_account_id=null else . end')
  after=$(printf '%s' "$STORE_JSON" | jq '.accounts | length')
  (( after < before )) || fail "Account not found"
  atomic_private_write "$store_path" "$STORE_JSON"
  home=$(account_home "$provider" "$account_id")
  if [[ -d $home && ! -L $home ]]; then rm -rf -- "$home"; fi
  jq -cn '{ok: true, message: "Removed saved account"}'
}

usage_unavailable() {
  local provider=$1 account_id=$2 reason=$3
  jq -cn --arg provider "$provider" --arg id "$account_id" --arg reason "$reason" \
    --arg fetched_at "$(utc_now)" '{
      ok: true,
      provider: $provider,
      account_id: $id,
      available: false,
      windows: [],
      reason: $reason,
      fetched_at: $fetched_at
    }'
}

provider_cli() {
  local provider=$1 directory candidate=''
  while IFS= read -r directory; do
    [[ -n $directory ]] || directory=.
    candidate="$directory/$provider"
    [[ -x $candidate && ! -d $candidate ]] || continue
    if head -c 4096 -- "$candidate" 2>/dev/null |
      grep -Fq 'omarchy-ai-account-switcher command router v1'; then
      continue
    fi
    printf '%s\n' "$candidate"
    return
  done < <(printf '%s' "$PATH" | tr ':' '\n')
  if command -v mise >/dev/null 2>&1; then
    candidate=$(mise which "$provider" 2>/dev/null || true)
    if [[ -n $candidate && -x $candidate ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  fi
  printf '\n'
}

codex_usage() {
  local account_id=$1 home=$2 account=$3 cli server_in server_out server_pid line response=''
  if [[ $(printf '%s' "$account" | jq -r '.auth_mode // empty') == api_key ]]; then
    usage_unavailable codex "$account_id" "Plan usage is unavailable for API key accounts"
    return
  fi
  cli=$(provider_cli codex)
  if [[ -z $cli ]]; then
    usage_unavailable codex "$account_id" "Codex is not installed"
    return
  fi

  coproc usage_server {
    CODEX_HOME="$home" timeout 15 "$cli" app-server --stdio 2>/dev/null
  }
  server_in=${usage_server[1]}
  server_out=${usage_server[0]}
  server_pid=$usage_server_PID
  printf '%s\n' \
    '{"method":"initialize","id":1,"params":{"clientInfo":{"name":"omarchy-ai-account-switcher","title":"Omarchy AI Account Switcher","version":"0.1.0"}}}' \
    '{"method":"initialized","params":{}}' \
    '{"method":"account/rateLimits/read","id":2,"params":{}}' >&"$server_in"

  while IFS= read -r -t 15 line <&"$server_out"; do
    if jq -e '.id == 2' >/dev/null 2>&1 <<<"$line"; then
      response=$line
      break
    fi
  done
  exec {server_in}>&-
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true

  if [[ -z $response ]] || ! jq -e '.result.rateLimits | type == "object"' \
    >/dev/null 2>&1 <<<"$response"; then
    usage_unavailable codex "$account_id" "Could not load Codex usage"
    return
  fi

  jq -c --arg provider codex --arg id "$account_id" --arg fetched_at "$(utc_now)" '
    def window_label:
      if . == 300 then "5h"
      elif . == 1440 then "24h"
      elif . == 10080 then "7d"
      elif . % 1440 == 0 then ((. / 1440 | tostring) + "d")
      elif . % 60 == 0 then ((. / 60 | tostring) + "h")
      else (tostring + "m") end;
    def bounded_percent:
      tonumber | if . < 0 then 0 elif . > 100 then 100 else . end;
    .result.rateLimits as $limits |
    [$limits.primary, $limits.secondary]
      | map(select(type == "object" and (.usedPercent | type) == "number"))
      | unique_by(.windowDurationMins)
      | map({
          key: (if .windowDurationMins == 300 then "five_hour"
            elif .windowDurationMins == 10080 then "seven_day"
            else ("window_" + (.windowDurationMins | tostring)) end),
          label: (.windowDurationMins | window_label),
          used_percent: (.usedPercent | bounded_percent),
          resets_at: (.resetsAt // null)
        }) as $windows |
    {
      ok: true,
      provider: $provider,
      account_id: $id,
      available: ($windows | length > 0),
      windows: $windows,
      reason: (if $windows | length > 0 then null else "No Codex plan limits were reported" end),
      plan_type: ($limits.planType // null),
      fetched_at: $fetched_at
    }
  ' <<<"$response"
}

claude_usage() {
  local account_id=$1 home=$2 cli output result
  cli=$(provider_cli claude)
  if [[ -z $cli ]]; then
    usage_unavailable claude "$account_id" "Claude Code is not installed"
    return
  fi
  if ! output=$(CLAUDE_CONFIG_DIR="$home" LC_ALL=C timeout 20 "$cli" --safe-mode \
    --no-session-persistence -p '/usage' --output-format json 2>/dev/null) ||
    ! result=$(printf '%s' "$output" | jq -er \
      'select(type == "object" and .is_error != true) | .result | select(type == "string")' \
      2>/dev/null); then
    usage_unavailable claude "$account_id" "Sign in to refresh Claude usage"
    return
  fi

  jq -cn --arg provider claude --arg id "$account_id" --arg text "$result" \
    --arg fetched_at "$(utc_now)" '
    def percent($pattern):
      [$text | split("\n")[] | capture($pattern)? | .percent | tonumber] | first;
    [
      {key: "five_hour", label: "5h",
        used_percent: percent("^Current session: (?<percent>[0-9]+(?:\\.[0-9]+)?)% used")},
      {key: "seven_day", label: "7d",
        used_percent: percent("^Current week \\(all models\\): (?<percent>[0-9]+(?:\\.[0-9]+)?)% used")}
    ] | map(select(.used_percent != null) | . + {resets_at: null}) as $windows |
    {
      ok: true,
      provider: $provider,
      account_id: $id,
      available: ($windows | length > 0),
      windows: $windows,
      reason: (if $windows | length > 0 then null else "Claude did not report plan limits" end),
      fetched_at: $fetched_at
    }'
}

account_usage() {
  local provider=$1 account_id=$2 store_path account home
  validate_account_id "$account_id"
  store_path=$(provider_store "$provider")
  load_store "$store_path"
  account=$(printf '%s' "$STORE_JSON" | jq -c --arg id "$account_id" \
    '.accounts[] | select(.id == $id)' | head -n 1)
  [[ -n $account ]] || fail "Account not found"
  home=$(account_home "$provider" "$account_id")
  if [[ ! -d $home || -L $home ]]; then
    usage_unavailable "$provider" "$account_id" "The private account home is unavailable"
    return
  fi
  case $provider in
    codex) codex_usage "$account_id" "$home" "$account" ;;
    claude) claude_usage "$account_id" "$home" ;;
    *) fail "Unknown provider: $provider" ;;
  esac
}

usage() {
  printf 'Usage: %s status | usage PROVIDER ID | import-current PROVIDER [NAME] [--inactive] | switch PROVIDER ID | prepare-launch PROVIDER [ID] | rename PROVIDER ID NAME | remove PROVIDER ID\n' "$0" >&2
  exit 2
}

main() {
  local command=${1:-}
  case $command in
    status)
      [[ $# == 1 ]] || usage
      combined_status
      ;;
    usage)
      [[ $# == 3 ]] || usage
      [[ $2 == codex || $2 == claude ]] || fail "Unknown provider: $2"
      account_usage "$2" "$3"
      ;;
    import-current)
      [[ $# -ge 2 ]] || usage
      local provider=$2 name='' activate=true argument
      shift 2
      for argument in "$@"; do
        if [[ $argument == --inactive ]]; then activate=false
        elif [[ -z $name ]]; then name=$argument
        else usage
        fi
      done
      [[ $provider == codex || $provider == claude ]] || fail "Unknown provider: $provider"
      import_current "$provider" "$name" "$activate"
      ;;
    switch)
      [[ $# == 3 ]] || usage
      switch_account "$2" "$3"
      ;;
    prepare-launch)
      [[ $# == 2 || $# == 3 ]] || usage
      [[ $2 == codex || $2 == claude ]] || fail "Unknown provider: $2"
      prepare_launch "$2" "${3:-}"
      ;;
    rename)
      [[ $# == 4 ]] || usage
      rename_account "$2" "$3" "$4"
      ;;
    remove)
      [[ $# == 3 ]] || usage
      remove_account "$2" "$3"
      ;;
    *) usage ;;
  esac
}

main "$@"
