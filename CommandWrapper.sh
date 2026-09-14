#!/bin/bash
# omarchy-ai-account-switcher command router v1

set -euo pipefail

find_real_command() {
  local self directory candidate resolved
  self=$(readlink -f -- "$0")
  while IFS= read -r directory; do
    [[ -n $directory ]] || directory=.
    candidate="$directory/claude"
    [[ -x $candidate && ! -d $candidate ]] || continue
    resolved=$(readlink -f -- "$candidate" 2>/dev/null || printf '%s' "$candidate")
    [[ $resolved != "$self" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done < <(printf '%s' "$PATH" | tr ':' '\n')
  return 1
}

if ! real_command=$(find_real_command); then
  echo "AI Account Switcher: could not find the real claude command" >&2
  exit 127
fi

# An explicit config directory always wins. This keeps nested sessions and the
# isolated add-account login flow pinned to the home they started with.
if [[ -n ${CLAUDE_CONFIG_DIR:-} ]]; then
  exec "$real_command" "$@"
fi

plugin_dir="${OMARCHY_AI_SWITCHER_PLUGIN_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/acrogenesis.ai-account-switcher}"
helper="$plugin_dir/ai_accounts.sh"

if [[ -x $helper ]]; then
  set +e
  result=$(bash "$helper" prepare-launch 2>/dev/null)
  result_status=$?
  set -e
  if (( result_status == 0 )) && home=$(jq -er '.home' <<<"$result" 2>/dev/null); then
    export CLAUDE_CONFIG_DIR="$home"
  fi
fi

exec "$real_command" "$@"
