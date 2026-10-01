#!/usr/bin/env bash
# pix.recast smoke test — validates manifest + Python syntax.
# Full QML load tests require the omarchy shell context (injected props, display server).
# Run this from within omarchy for end-to-end testing.
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0
fail=0

echo_title() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
ok()   { printf '\033[32m  ok: %s\033[0m\n' "$1"; pass=$((pass+1)); }
bad()  { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; fail=$((fail+1)); }

have() { command -v "$1" >/dev/null 2>&1; }

echo_title "Validating manifest"
if have omarchy; then
  if omarchy plugin validate "$PLUGIN_DIR" >/dev/null 2>&1; then
    ok "omarchy plugin validate"
  else
    bad "omarchy plugin validate"
  fi
else
  echo "  omarchy CLI not found; skipping manifest validation"
fi

if jq -e '.schemaVersion == 1 and .id == "pix.recast"
        and ([.kinds[]] | index("service"))
        and ([.kinds[]] | index("bar-widget"))
        and .entryPoints.service
        and .entryPoints.barWidget' \
   "$PLUGIN_DIR/manifest.json" >/dev/null 2>&1; then
  ok "manifest structure valid"
else
  bad "manifest structure"
fi

echo_title "Python scripts"
if have python3; then
  for py in "$PLUGIN_DIR/scripts"/*.py; do
    if python3 -m py_compile "$py" 2>/dev/null; then
      ok "$(basename "$py") compiles"
    else
      bad "$(basename "$py") compiles"
    fi
  done
fi

echo_title "Key QML files exist"
for f in Service.qml BarWidget.qml Panel.qml; do
  if [ -f "$PLUGIN_DIR/$f" ]; then
    ok "$f exists"
  else
    bad "$f exists"
  fi
done

echo_title "JS logic"
if have node; then
  if node "$PLUGIN_DIR/tests/logic.test.js"; then
    ok "logic.test.js"
  else
    bad "logic.test.js"
  fi
else
  echo "  node not found; skipping JS logic tests"
fi

echo_title "Update checker script"
if [ -x "$PLUGIN_DIR/scripts/check-update.sh" ]; then
  if JSON=$(bash "$PLUGIN_DIR/scripts/check-update.sh" 2>/dev/null); then
    if echo "$JSON" | jq -e '.update_available != null and .current_version != null and .new_version != null' >/dev/null 2>&1; then
      ok "check-update.sh emits valid JSON"
    else
      bad "check-update.sh JSON shape"
    fi
  else
    bad "check-update.sh runs"
  fi
else
  bad "check-update.sh is executable"
fi

echo_title "Results"
echo "  passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]