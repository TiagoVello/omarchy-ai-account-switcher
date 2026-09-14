#!/bin/bash

set -euo pipefail

plugin_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
helper="$plugin_dir/ai_accounts.sh"
login_home=""
source_home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
source_state="${CLAUDE_CONFIG_DIR:+$CLAUDE_CONFIG_DIR/.claude.json}"
source_state="${source_state:-$HOME/.claude.json}"

cleanup() {
  if [[ -n $login_home && -d $login_home ]]; then
    rm -rf -- "$login_home"
  fi
}

trap cleanup EXIT

run_helper() {
  local output status
  set +e
  output="$(bash "$helper" "$@")"
  status=$?
  set -e
  jq -r '.message // .error // "Done"' <<<"$output"
  return "$status"
}

if [[ -t 1 ]]; then clear; fi
echo "AI Account Switcher · Claude"
echo

if [[ -f ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json ]]; then
  run_helper import-current
fi

login_home="$(mktemp -d)"
CLAUDE_CONFIG_DIR="$login_home" claude auth login

echo
read -r -p "Name for the new Claude login (Enter uses its email): " new_name
CLAUDE_CONFIG_DIR="$login_home" OMARCHY_AI_SOURCE_CLAUDE_CONFIG_DIR="$source_home" \
  OMARCHY_AI_SOURCE_CLAUDE_STATE="$source_state" \
  run_helper import-current "$new_name" --inactive

echo
echo "The new Claude account is saved. Select and open it from the bar whenever you want."
read -r -p "Press Enter to close..."
