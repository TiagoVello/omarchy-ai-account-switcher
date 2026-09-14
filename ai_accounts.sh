#!/bin/bash

set -Eeu -o pipefail

CONFIG_DIR="${OMARCHY_AI_SWITCHER_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/ai-account-switcher}"
HOMES_DIR="$CONFIG_DIR/homes"
STORE_FILE="$CONFIG_DIR/claude-accounts.json"

source_home() {
  printf '%s\n' "${OMARCHY_AI_SOURCE_CLAUDE_CONFIG_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"
}

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

validate_account_id() {
  [[ $1 =~ ^[A-Za-z0-9_-]+$ ]] || fail "Invalid account id"
}

account_home() {
  local account_id=$1
  validate_account_id "$account_id"
  printf '%s/claude/%s\n' "$HOMES_DIR" "$account_id"
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
  local home=$1 source entry target
  source=$(source_home)
  for entry in CLAUDE.md hooks plugins settings.json skills themes; do
    target="$home/$entry"
    if [[ ( -e $source/$entry || -L $source/$entry ) && ! -e $target && ! -L $target ]]; then
      ln -s -- "$source/$entry" "$target"
    fi
  done
}

load_store() {
  if [[ ! -e $STORE_FILE ]]; then
    STORE_JSON='{"version":2,"accounts":[],"active_account_id":null}'
    return
  fi
  if [[ -L $STORE_FILE ]]; then fail "Refusing to read symlink: $STORE_FILE"; fi
  if ! STORE_JSON=$(jq -c '
    if type != "object" or (.accounts | type) != "array" then
      error("invalid account store")
    else
      .version = 2 | .active_account_id //= null
    end
  ' "$STORE_FILE" 2>/dev/null); then
    fail "Could not read $(basename "$STORE_FILE")"
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

running_processes() {
  ps -axo pid=,tty=,comm=,args= | awk '
    {
      pid=$1; tty=$2; comm=$3
      $1=$2=$3=""; sub(/^[[:space:]]+/, "", $0); args=$0
      split(args, words, /[[:space:]]+/)
      first=words[1]; sub(/^.*\//, "", first)
      command=comm; sub(/^.*\//, "", command)
      if (tty == "?" || tty == "??" || tty == "-") next
      if (command == "claude" || first == "claude") print pid
    }
  '
}

running_count() {
  running_processes | awk 'NF { count++ } END { print count + 0 }'
}

account_status() {
  local current index current_id active_id count has_current suggested
  load_store
  current=$(claude_current_account false)
  current_id=''
  if [[ $current != null ]]; then
    index=$(claude_match_index "$current")
    if (( index >= 0 )); then current_id=$(printf '%s' "$STORE_JSON" | jq -r --argjson index "$index" '.accounts[$index].id'); fi
  fi
  active_id=$(printf '%s' "$STORE_JSON" | jq -r '.active_account_id // empty')
  if [[ -z $active_id ]]; then active_id=$current_id; fi
  count=$(running_count)
  if [[ $current == null ]]; then has_current=false; suggested=''; else has_current=true; suggested=$(printf '%s' "$current" | jq -r '.name // empty'); fi

  printf '%s' "$STORE_JSON" | jq -c \
    --arg active "$active_id" --arg current "$current_id" --arg suggested "$suggested" \
    --argjson has_current "$has_current" --argjson count "$count" '{
      accounts: [.accounts[] | {
        id: (.id | tostring), name: (.name // "Account"), email, org_name, subscription_type,
        is_active: (.id == $active), is_current: (.id == $current), last_used_at
      }],
      active_account_id: (if $active == "" then null else $active end),
      current_saved: ($current != ""), has_current_login: $has_current,
      suggested_name: $suggested, can_switch: true, running_count: $count
    }'
}

combined_status() {
  local claude wrappers=false marker='omarchy-ai-account-switcher command router v1'
  local wrapper_bin="${OMARCHY_AI_SWITCHER_BIN_DIR:-$HOME/.local/bin}"
  local mise_marker='omarchy-ai-account-switcher mise aliases v1'
  local mise_conf_dir="${OMARCHY_AI_SWITCHER_MISE_CONF_DIR:-${MISE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/mise}/conf.d}"
  local mise_fragment="$mise_conf_dir/omarchy-ai-account-switcher.toml"
  claude=$(account_status)
  if [[ -f $wrapper_bin/claude && ! -L $wrapper_bin/claude ]] &&
    grep -Fq "$marker" "$wrapper_bin/claude" 2>/dev/null &&
    [[ -f $mise_fragment && ! -L $mise_fragment ]] &&
    grep -Fq "$mise_marker" "$mise_fragment" 2>/dev/null; then
    wrappers=true
  fi
  jq -cn --slurpfile claude <(printf '%s\n' "$claude") --argjson wrappers "$wrappers" \
    '{ok: true, command_wrappers_enabled: $wrappers} + $claude[0]'
}

import_current() {
  local name=$1 activate=$2 candidate index saved_id saved_name
  local previous_active existing_id existing_name existing_created existing_last
  lock_store
  load_store
  previous_active=$(printf '%s' "$STORE_JSON" | jq -r '.active_account_id // empty')
  candidate=$(claude_current_account true)
  if [[ $candidate == null ]]; then fail "No Claude login is available to save"; fi
  index=$(claude_match_index "$candidate")

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
  materialize_account_home "$candidate" true >/dev/null
  atomic_private_write "$STORE_FILE" "$STORE_JSON"
  jq -cn --arg message "Saved $saved_name" '{ok: true, message: $message}'
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
  source="$(source_home)/.credentials.json"
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
  local account=$1 force=${2:-false} id home credential had_credential=false
  id=$(printf '%s' "$account" | jq -r '.id')
  home=$(account_home "$id")
  ensure_private_directory "$CONFIG_DIR"
  ensure_private_directory "$HOMES_DIR"
  ensure_private_directory "$HOMES_DIR/claude"
  ensure_private_directory "$home"
  link_shared_config "$home"

  credential="$home/.credentials.json"
  if [[ -e $credential ]]; then had_credential=true; fi
  seed_claude_credentials "$home"
  seed_claude_state "$home"
  link_shared_claude_history "$account" "$home"
  if [[ $force == true || $had_credential == false ]]; then
    [[ ! -L $credential ]] || fail "Refusing to replace symlink: $credential"
    printf '%s' "$account" | write_claude_account "$home"
  fi
  printf '%s\n' "$home"
}

sync_account_home_into_store() {
  local account_id=$1 home current index existing_name existing_created existing_last
  home=$(account_home "$account_id")
  [[ -f $home/.credentials.json && ! -L $home/.credentials.json ]] || return 0
  current=$(CLAUDE_CONFIG_DIR="$home" claude_current_account false)
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
  local account_id=$1 target now name
  lock_store
  load_store
  target=$(printf '%s' "$STORE_JSON" | jq -c --arg id "$account_id" '.accounts[] | select(.id == $id)' | head -n 1)
  [[ -n $target ]] || fail "Account not found"
  materialize_account_home "$target" false >/dev/null
  sync_account_home_into_store "$account_id"
  now=$(utc_now)
  STORE_JSON=$(printf '%s' "$STORE_JSON" | jq -c --arg id "$account_id" --arg now "$now" '
    .active_account_id=$id | .accounts |= map(if .id == $id then .last_used_at=$now else . end)')
  atomic_private_write "$STORE_FILE" "$STORE_JSON"
  name=$(printf '%s' "$target" | jq -r '.name')
  jq -cn --arg message "Selected $name for new sessions" '{ok: true, message: $message}'
}

prepare_launch() {
  local account_id=${1:-} target home now name
  lock_store
  load_store
  if [[ -z $account_id ]]; then account_id=$(printf '%s' "$STORE_JSON" | jq -r '.active_account_id // empty'); fi
  [[ -n $account_id ]] || fail "Select a saved Claude account first"
  target=$(printf '%s' "$STORE_JSON" | jq -c --arg id "$account_id" '.accounts[] | select(.id == $id)' | head -n 1)
  [[ -n $target ]] || fail "Account not found"
  home=$(materialize_account_home "$target" false)
  sync_account_home_into_store "$account_id"
  now=$(utc_now)
  STORE_JSON=$(printf '%s' "$STORE_JSON" | jq -c --arg id "$account_id" --arg now "$now" '
    .active_account_id=$id | .accounts |= map(if .id == $id then .last_used_at=$now else . end)')
  atomic_private_write "$STORE_FILE" "$STORE_JSON"
  name=$(printf '%s' "$STORE_JSON" | jq -r --arg id "$account_id" '.accounts[] | select(.id == $id) | .name')
  jq -cn --arg id "$account_id" --arg name "$name" --arg home "$home" \
    '{ok: true, account_id: $id, name: $name, home: $home}'
}

rename_account() {
  local account_id=$1 name=$2 count
  [[ -n ${name//[[:space:]]/} ]] || fail "Account name cannot be empty"
  lock_store
  load_store
  count=$(printf '%s' "$STORE_JSON" | jq -r --arg id "$account_id" '[.accounts[] | select(.id == $id)] | length')
  (( count > 0 )) || fail "Account not found"
  STORE_JSON=$(printf '%s' "$STORE_JSON" | jq -c --arg id "$account_id" --arg name "$name" \
    '.accounts |= map(if .id == $id then .name=$name else . end)')
  atomic_private_write "$STORE_FILE" "$STORE_JSON"
  jq -cn --arg message "Renamed account to $name" '{ok: true, message: $message}'
}

remove_account() {
  local account_id=$1 before after home
  lock_store
  load_store
  before=$(printf '%s' "$STORE_JSON" | jq '.accounts | length')
  STORE_JSON=$(printf '%s' "$STORE_JSON" | jq -c --arg id "$account_id" '
    .accounts |= map(select(.id != $id)) |
    if .active_account_id == $id then .active_account_id=null else . end')
  after=$(printf '%s' "$STORE_JSON" | jq '.accounts | length')
  (( after < before )) || fail "Account not found"
  atomic_private_write "$STORE_FILE" "$STORE_JSON"
  home=$(account_home "$account_id")
  if [[ -d $home && ! -L $home ]]; then rm -rf -- "$home"; fi
  jq -cn '{ok: true, message: "Removed saved account"}'
}

usage_unavailable() {
  local account_id=$1 reason=$2
  jq -cn --arg id "$account_id" --arg reason "$reason" \
    --arg fetched_at "$(utc_now)" '{
      ok: true,
      account_id: $id,
      available: false,
      windows: [],
      reason: $reason,
      fetched_at: $fetched_at
    }'
}

claude_cli() {
  local directory candidate=''
  while IFS= read -r directory; do
    [[ -n $directory ]] || directory=.
    candidate="$directory/claude"
    [[ -x $candidate && ! -d $candidate ]] || continue
    if head -c 4096 -- "$candidate" 2>/dev/null |
      grep -Fq 'omarchy-ai-account-switcher command router v1'; then
      continue
    fi
    printf '%s\n' "$candidate"
    return
  done < <(printf '%s' "$PATH" | tr ':' '\n')
  if command -v mise >/dev/null 2>&1; then
    candidate=$(mise which claude 2>/dev/null || true)
    if [[ -n $candidate && -x $candidate ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  fi
  printf '\n'
}

claude_usage() {
  local account_id=$1 home=$2 cli output result
  cli=$(claude_cli)
  if [[ -z $cli ]]; then
    usage_unavailable "$account_id" "Claude Code is not installed"
    return
  fi
  if ! output=$(CLAUDE_CONFIG_DIR="$home" LC_ALL=C timeout 20 "$cli" --safe-mode \
    --no-session-persistence -p '/usage' --output-format json 2>/dev/null) ||
    ! result=$(printf '%s' "$output" | jq -er \
      'select(type == "object" and .is_error != true) | .result | select(type == "string")' \
      2>/dev/null); then
    usage_unavailable "$account_id" "Sign in to refresh Claude usage"
    return
  fi

  jq -cn --arg id "$account_id" --arg text "$result" \
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
      account_id: $id,
      available: ($windows | length > 0),
      windows: $windows,
      reason: (if $windows | length > 0 then null else "Claude did not report plan limits" end),
      fetched_at: $fetched_at
    }'
}

account_usage() {
  local account_id=$1 account home
  validate_account_id "$account_id"
  load_store
  account=$(printf '%s' "$STORE_JSON" | jq -c --arg id "$account_id" \
    '.accounts[] | select(.id == $id)' | head -n 1)
  [[ -n $account ]] || fail "Account not found"
  home=$(account_home "$account_id")
  if [[ ! -d $home || -L $home ]]; then
    usage_unavailable "$account_id" "The private account home is unavailable"
    return
  fi
  claude_usage "$account_id" "$home"
}

usage() {
  printf 'Usage: %s status | usage ID | import-current [NAME] [--inactive] | switch ID | prepare-launch [ID] | rename ID NAME | remove ID\n' "$0" >&2
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
      [[ $# == 2 ]] || usage
      account_usage "$2"
      ;;
    import-current)
      local name='' activate=true argument
      shift || true
      for argument in "$@"; do
        if [[ $argument == --inactive ]]; then activate=false
        elif [[ -z $name ]]; then name=$argument
        else usage
        fi
      done
      import_current "$name" "$activate"
      ;;
    switch)
      [[ $# == 2 ]] || usage
      switch_account "$2"
      ;;
    prepare-launch)
      [[ $# == 1 || $# == 2 ]] || usage
      prepare_launch "${2:-}"
      ;;
    rename)
      [[ $# == 3 ]] || usage
      rename_account "$2" "$3"
      ;;
    remove)
      [[ $# == 2 ]] || usage
      remove_account "$2"
      ;;
    *) usage ;;
  esac
}

main "$@"
