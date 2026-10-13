#!/usr/bin/env bash
# Shared, dependency-light helpers for the Mizzy Smart Agent Loop.
# This file is safe to source from the launcher and shell smoke tests.

mizzy_is_critical_task() {
  local task_slug="${1:-}"
  local task_description="${2:-}"
  printf '%s\n%s\n' "$task_slug" "$task_description" |
    grep -Eiq '(auth|authorization|security|credential|privacy|RLS|tenant|branch[- ]scope|cross[- ](tenant|branch)|payment|financial|billing|refund|void|cash|tax|ledger|money|idempotenc|replay|inventory|stock|offline|sync|migration|schema|backup|restore|release|production|deploy)'
}

# Print all changed test files that currently exist. The caller falls back to
# the full suite if this prints nothing. Includes staged/unstaged and untracked
# test files, and filters deleted files so they are not passed to Flutter.
mizzy_changed_test_files() {
  local test_file
  while IFS= read -r test_file; do
    if [[ -f "$test_file" ]]; then
      printf '%s\n' "$test_file"
    fi
  done < <(
    {
      git diff --name-only HEAD -- test/
      git ls-files --others --exclude-standard -- test/
    } | grep -E '^test/.*_test\.dart$' | sort -u || true
  )
}
