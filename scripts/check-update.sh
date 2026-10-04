#!/usr/bin/env bash
# pix.recast check-update.sh — emits one-line JSON for Panel.qml.
# Always exits 0 (fail-soft); fields describe the current state.
set -uo pipefail

PLUGIN_ID="pix.recast"
REPO="pxllbt/better-recast"
BRANCH="main"
RAW_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/manifest.json"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

current_version="0.0.0"
current_commit=""
current_commit_short=""
if [[ -f "$PLUGIN_DIR/manifest.json" ]]; then
  current_version=$(jq -r '.version // "0.0.0"' "$PLUGIN_DIR/manifest.json" 2>/dev/null || echo "0.0.0")
fi
if git -C "$PLUGIN_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  current_commit_full=$(git -C "$PLUGIN_DIR" rev-parse HEAD 2>/dev/null || echo "")
  current_commit_short=$(git -C "$PLUGIN_DIR" rev-parse --short HEAD 2>/dev/null || echo "")
fi

update_available=false
new_version=""
new_commit=""
commits_behind=0
error=""

MAX_REMOTE_SIZE=65536
remote_json=""
remote_json=$(curl -fsSL --max-time 10 "$RAW_URL" 2>/dev/null | head -c "$((MAX_REMOTE_SIZE + 1))") || error="network"
if [[ -n "$remote_json" && ${#remote_json} -gt "$MAX_REMOTE_SIZE" ]]; then
  error="response too large"
  remote_json=""
fi
if [[ -n "$remote_json" ]]; then
  new_version=$(jq -r '.version // empty' <<<"$remote_json" 2>/dev/null || echo "")
  # Reject arbitrary version strings — must be semver-like
  if [[ -n "$new_version" && ! "$new_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?$ ]]; then
    error="invalid version format"
    new_version=""
  fi
fi

if git -C "$PLUGIN_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  if timeout 30 git -C "$PLUGIN_DIR" fetch --quiet origin "$BRANCH" 2>/dev/null; then
    new_commit_full=$(git -C "$PLUGIN_DIR" rev-parse --short FETCH_HEAD 2>/dev/null || echo "")
    commits_behind=$(git -C "$PLUGIN_DIR" rev-list --count HEAD..FETCH_HEAD 2>/dev/null || echo 0)
    if [[ "$commits_behind" -gt 0 ]]; then
      update_available=true
    fi
  fi
fi

if [[ "$update_available" == "false" && -n "$new_version" && -n "$current_version" ]]; then
  if [[ "$new_version" != "$current_version" ]]; then
    sorted=$(printf '%s\n%s\n' "$current_version" "$new_version" | sort -V | head -n1)
    if [[ "$sorted" == "$current_version" && "$sorted" != "$new_version" ]]; then
      update_available=true
    fi
  fi
fi

jq -nc \
  --argjson update_available "$update_available" \
  --arg current_version "$current_version" \
  --arg new_version "$new_version" \
  --arg current_commit "$current_commit_short" \
  --arg new_commit "$new_commit_full" \
  --argjson commits_behind "$commits_behind" \
  --arg error "$error" \
  '{
    update_available: $update_available,
    current_version: $current_version,
    new_version: $new_version,
    current_commit: $current_commit,
    new_commit: $new_commit,
    commits_behind: $commits_behind,
    error: $error
  }'
