#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="$ROOT/scripts/mizzy-agent-loop.sh"
source "$ROOT/scripts/mizzy-agent-loop-lib.sh"
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


# Critical task classification must include the task slug and description.
mizzy_is_critical_task "payment-refund" "Fix the order workflow" ||
  fail "payment/refund task was not classified as critical"
mizzy_is_critical_task "ui-copy" "Review tenant RLS isolation" ||
  fail "tenant/RLS task was not classified as critical"
if mizzy_is_critical_task "ui-copy" "Adjust button spacing"; then
  fail "low-risk UI copy task was incorrectly classified as critical"
fi

# Test discovery must include staged tracked and untracked tests and skip deletes.
selection_repo="$TEMP_ROOT/test-selection-repo"
mkdir -p "$selection_repo/test"
git -C "$selection_repo" init -q -b feature/test-selection
git -C "$selection_repo" config user.name "Mizzy Agent Loop Test"
git -C "$selection_repo" config user.email "mizzy-agent-loop-test@example.invalid"
printf 'void main() {}\\n' > "$selection_repo/test/changed_test.dart"
printf 'void main() {}\\n' > "$selection_repo/test/deleted_test.dart"
git -C "$selection_repo" add test
git -C "$selection_repo" commit -qm "fixture: test discovery baseline"
printf '// changed\\n' >> "$selection_repo/test/changed_test.dart"
git -C "$selection_repo" add test/changed_test.dart
rm "$selection_repo/test/deleted_test.dart"
printf 'void main() {}\\n' > "$selection_repo/test/new_untracked_test.dart"
selected="$(cd "$selection_repo" && mizzy_changed_test_files)"
grep -Fxq "test/changed_test.dart" <<< "$selected" ||
  fail "staged tracked test was not discovered"
grep -Fxq "test/new_untracked_test.dart" <<< "$selected" ||
  fail "untracked test was not discovered"
if grep -Fq "deleted_test.dart" <<< "$selected"; then
  fail "deleted test was incorrectly selected"
fi

# No changed current test files must produce an empty list for full-suite fallback.
git -C "$selection_repo" reset --hard -q HEAD
rm -f "$selection_repo/test/new_untracked_test.dart"
selected="$(cd "$selection_repo" && mizzy_changed_test_files)"
[[ -z "$selected" ]] || fail "test discovery should be empty for a clean test tree"

echo "PASS: launcher refuses protected main branch and dirty working tree"
