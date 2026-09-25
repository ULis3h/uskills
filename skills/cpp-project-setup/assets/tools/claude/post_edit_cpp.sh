#!/usr/bin/env bash
# Claude Code PostToolUse hook for Edit/Write/MultiEdit.
#
# Formats the C++ file Claude just touched and, when a compile database is
# available, runs clang-tidy on it. Findings are returned to Claude as
# blocking feedback (exit 2) so they get fixed before the work continues,
# which is what makes the cpp-style/cpp-safety rules enforced rather than
# advisory.
#
# Install: see claude-settings.json in the same directory.
# Disable temporarily: CPP_HOOKS=0 claude
set -u

[ "${CPP_HOOKS:-1}" = "0" ] && exit 0

input=$(cat)
file=$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("tool_input", {}).get("file_path", ""))
except Exception:
    print("")
' 2>/dev/null)

case "$file" in
  *.cc|*.cpp|*.cxx|*.h|*.hpp|*.hxx|*.inl) ;;
  *) exit 0 ;;
esac
[ -f "$file" ] || exit 0

root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$root" || exit 0

# 1. Format in place. Cheap and never wrong when .clang-format is the source of truth.
if command -v clang-format >/dev/null 2>&1; then
  clang-format -i --style=file "$file" 2>/dev/null
fi

# 2. clang-tidy, only for translation units and only with a compile database.
case "$file" in *.h|*.hpp|*.hxx|*.inl) exit 0 ;; esac   # headers are checked via the .cc that includes them
command -v clang-tidy >/dev/null 2>&1 || exit 0

db=""
for d in build/dev build/debug build; do
  if [ -f "$d/compile_commands.json" ]; then db="$d"; break; fi
done
[ -n "$db" ] || exit 0

findings=$(clang-tidy -p "$db" --quiet "$file" 2>/dev/null | grep -E '(warning|error): ' | grep -v 'warnings generated' | head -40)
if [ -n "$findings" ]; then
  {
    echo "clang-tidy reported findings in $file. Fix the code (do not add NOLINT unless it is a documented false positive):"
    echo "$findings"
  } >&2
  exit 2
fi
exit 0
