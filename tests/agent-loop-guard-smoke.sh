#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="$ROOT/scripts/mizzy-agent-loop.sh"
TEMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEMP_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# The launcher must refuse the protected main branch before checking tools.
main_repo="$TEMP_ROOT/main-repo"
mkdir -p "$main_repo"
git -C "$main_repo" init -q -b main
git -C "$main_repo" config user.name "Mizzy Agent Loop Test"
git -C "$main_repo" config user.email "mizzy-agent-loop-test@example.invalid"
cp "$LAUNCHER" "$main_repo/mizzy-agent-loop.sh"
if output="$(cd "$main_repo" && bash ./mizzy-agent-loop.sh smoke "must refuse main" 2>&1)"; then
  fail "launcher unexpectedly accepted main branch"
fi
grep -q "switch to a dedicated feature branch" <<< "$output" ||
  fail "main-branch rejection message was not emitted"

# A dirty feature branch must also be rejected before any model CLI is invoked.
dirty_repo="$TEMP_ROOT/dirty-repo"
mkdir -p "$dirty_repo/docs"
git -C "$dirty_repo" init -q -b feature/smoke
git -C "$dirty_repo" config user.name "Mizzy Agent Loop Test"
git -C "$dirty_repo" config user.email "mizzy-agent-loop-test@example.invalid"
cp "$LAUNCHER" "$dirty_repo/mizzy-agent-loop.sh"
for file in AGENT.md AGENTS.md CLAUDE.md docs/agent-orchestration.md; do
  printf '# test fixture\n' > "$dirty_repo/$file"
done
git -C "$dirty_repo" add .
git -C "$dirty_repo" commit -qm "fixture: clean feature branch"
printf '\n# dirty marker\n' >> "$dirty_repo/AGENT.md"
if output="$(cd "$dirty_repo" && bash ./mizzy-agent-loop.sh smoke "must refuse dirty tree" 2>&1)"; then
  fail "launcher unexpectedly accepted dirty working tree"
fi
grep -q "working tree has tracked changes" <<< "$output" ||
  fail "dirty-tree rejection message was not emitted"

echo "PASS: launcher refuses protected main branch and dirty working tree"
