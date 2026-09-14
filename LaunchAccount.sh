#!/bin/bash

set -euo pipefail

plugin_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
helper="$plugin_dir/ai_accounts.sh"
account_id=${1:-}

result=$(bash "$helper" prepare-launch "$account_id")
if ! jq -e '.ok == true' >/dev/null 2>&1 <<<"$result"; then
  jq -r '.error // "Could not prepare account"' <<<"$result" >&2
  exit 1
fi

account_home=$(jq -r '.home' <<<"$result")
account_name=$(jq -r '.name' <<<"$result")

command -v claude >/dev/null 2>&1 || { echo "Claude is not installed" >&2; exit 1; }
printf 'Claude · %s\n\n' "$account_name"
export CLAUDE_CONFIG_DIR="$account_home"
exec claude
