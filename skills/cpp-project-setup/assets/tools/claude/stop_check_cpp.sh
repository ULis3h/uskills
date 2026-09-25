#!/usr/bin/env bash
# Claude Code Stop hook.
#
# Refuses to let Claude declare the task finished while there are modified
# C++ files that do not build warning-free or do not pass the tests. This is
# the "definition of done" from CLAUDE.md turned into a mechanical gate:
# Claude sees the failing output and keeps working.
#
# Uses the `dev` CMake preset (configure once with `cmake --preset dev`).
# Disable temporarily: CPP_HOOKS=0 claude   or   CPP_STOP_CHECK=0 claude
set -u

[ "${CPP_HOOKS:-1}" = "0" ] && exit 0
[ "${CPP_STOP_CHECK:-1}" = "0" ] && exit 0

input=$(cat)
# If this stop was already blocked once and Claude is stopping again, let it
# through: the hook must not create an infinite loop.
active=$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    print("1" if json.load(sys.stdin).get("stop_hook_active") else "0")
except Exception:
    print("0")
' 2>/dev/null)
[ "$active" = "1" ] && exit 0

root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$root" || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

changed=$( { git diff --name-only HEAD -- '*.cc' '*.cpp' '*.cxx' '*.h' '*.hpp' '*.inl' 'CMakeLists.txt' '*.cmake';
             git ls-files --others --exclude-standard -- '*.cc' '*.cpp' '*.cxx' '*.h' '*.hpp' '*.inl'; } 2>/dev/null | sort -u)
[ -z "$changed" ] && exit 0

preset="${CPP_STOP_PRESET:-dev}"
log=$(mktemp)
trap 'rm -f "$log"' EXIT

if [ ! -d "build/$preset" ]; then
  if ! cmake --preset "$preset" >"$log" 2>&1; then
    { echo "C++ files changed but 'cmake --preset $preset' failed. Configure the build before finishing:"; tail -30 "$log"; } >&2
    exit 2
  fi
fi

if ! cmake --build --preset "$preset" >"$log" 2>&1; then
  { echo "C++ files changed but the build fails (preset '$preset'). Fix these before finishing:"; grep -E '(error|warning|note): ' "$log" | head -40; } >&2
  exit 2
fi

if ! ctest --preset "$preset" >"$log" 2>&1; then
  { echo "C++ files changed but tests fail (preset '$preset'). Fix these before finishing:"; grep -vE '^\s*$' "$log" | tail -40; } >&2
  exit 2
fi

exit 0
