#!/usr/bin/env bash
# Safe local multi-agent loop for Mizzy. Never commits, pushes, merges or deploys.
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage:
  bash scripts/mizzy-agent-loop.sh <task-slug> <task description>

Required:
  Run from a clean feature branch in the Mizzy repo.
  Have Git, Flutter/Dart and at least one authenticated Codex or Claude Code CLI.

Optional environment:
  MIZZY_IMPLEMENTER=auto|codex|claude   (default: auto, prefer Codex)
  MIZZY_REVIEWER=auto|codex|claude|same (default: independent provider if available)
  MIZZY_VERIFY=targeted|full            (default: targeted)
  MIZZY_TARGET_TEST=test/path_test.dart (optional explicit test; otherwise changed tests or full suite)
  MIZZY_AGENT_MAX_TURNS=8              (Claude Code turn cap)
  MIZZY_RUN_SUPABASE_TESTS=1            (opt-in for noncritical tasks; critical tasks auto-enable)
USAGE
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" || $# -lt 2 ]]; then
  usage
  exit $([[ $# -lt 2 && ${1:-} != "-h" && ${1:-} != "--help" ]] && echo 2 || echo 0)
fi

TASK_SLUG="$1"
shift
TASK_DESCRIPTION="$*"

if [[ ! "$TASK_SLUG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
  echo "ERROR: task-slug may contain only letters, digits, dot, underscore and dash." >&2
  exit 2
fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "ERROR: not inside a Git worktree." >&2
  exit 2
}
cd "$ROOT"
BRANCH="$(git branch --show-current)"
if [[ -z "$BRANCH" || "$BRANCH" == "main" || "$BRANCH" == "master" ]]; then
  echo "ERROR: switch to a dedicated feature branch before running agents (current: ${BRANCH:-detached HEAD})." >&2
  exit 2
fi
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "ERROR: working tree has tracked changes. Commit/stash them before this agent run." >&2
  exit 2
fi
if [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
  echo "ERROR: working tree has untracked files. Commit/stash them before this agent run." >&2
  exit 2
fi
if [[ ! -f AGENT.md || ! -f AGENTS.md || ! -f CLAUDE.md || ! -f docs/agent-orchestration.md ]]; then
  echo "ERROR: shared agent rules are missing. Restore AGENT.md, AGENTS.md, CLAUDE.md and docs/agent-orchestration.md." >&2
  exit 2
fi

# Prevent accidental execution in a sibling POS repository.
ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
if [[ -z "$ORIGIN_URL" ]]; then
  echo "ERROR: origin remote is missing; run this loop only from mizzysbistro/mizzy." >&2
  exit 2
fi
ORIGIN_PATH="${ORIGIN_URL#*@}"
if [[ "$ORIGIN_PATH" == *github.com/* ]]; then
  ORIGIN_PATH="${ORIGIN_PATH#*github.com/}"
elif [[ "$ORIGIN_PATH" == *github.com:* ]]; then
  ORIGIN_PATH="${ORIGIN_PATH#*github.com:}"
else
  echo "ERROR: origin remote must point to mizzysbistro/mizzy on GitHub." >&2
  exit 2
fi
ORIGIN_PATH="${ORIGIN_PATH%/}"
ORIGIN_PATH="${ORIGIN_PATH%.git}"
if [[ "$ORIGIN_PATH" != "mizzysbistro/mizzy" ]]; then
  echo "ERROR: origin remote must point to mizzysbistro/mizzy on GitHub." >&2
  exit 2
fi
if [[ ! -f "$ROOT/scripts/mizzy-agent-loop-lib.sh" ]]; then
  echo "ERROR: required helper scripts/mizzy-agent-loop-lib.sh is missing." >&2
  exit 2
fi
# shellcheck source=scripts/mizzy-agent-loop-lib.sh
source "$ROOT/scripts/mizzy-agent-loop-lib.sh"

# Critical POS/security work cannot use the fast verification lane.
CRITICAL_TASK=0
if mizzy_is_critical_task "$TASK_SLUG" "$TASK_DESCRIPTION"; then
  CRITICAL_TASK=1
  echo "ROUTE: critical lane; independent cross-provider review is required for PASS."
  if [[ "${MIZZY_VERIFY:-targeted}" != "full" ]]; then
    echo "ROUTE: critical task forces full Flutter, APK/checksum and Gitleaks verification."
  fi
  if [[ "${MIZZY_RUN_SUPABASE_TESTS:-0}" != "1" ]]; then
    echo "ROUTE: critical task forces local Supabase database tests."
    MIZZY_RUN_SUPABASE_TESTS=1
  fi
fi

for command_name in git dart flutter; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "ERROR: required command '$command_name' is not installed or not on PATH." >&2
    exit 2
  fi
done

has_codex=0
has_claude=0
command -v codex >/dev/null 2>&1 && has_codex=1
command -v claude >/dev/null 2>&1 && has_claude=1
if [[ "$has_codex" -eq 0 && "$has_claude" -eq 0 ]]; then
  echo "ERROR: neither 'codex' nor 'claude' was found on PATH." >&2
  exit 2
fi

MAX_TURNS="${MIZZY_AGENT_MAX_TURNS:-8}"
if [[ ! "$MAX_TURNS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: MIZZY_AGENT_MAX_TURNS must be a positive integer." >&2
  exit 2
fi
MAX_ATTEMPTS=3

choose_provider() {
  local requested="$1"
  local role="$2"
  case "$requested" in
    codex)
      [[ "$has_codex" -eq 1 ]] || { echo "ERROR: requested Codex CLI is unavailable." >&2; return 2; }
      printf 'codex'
      ;;
    claude)
      [[ "$has_claude" -eq 1 ]] || { echo "ERROR: requested Claude Code CLI is unavailable." >&2; return 2; }
      printf 'claude'
      ;;
    auto)
      if [[ "$role" == "implementer" ]]; then
        if [[ "$has_codex" -eq 1 ]]; then printf 'codex'; else printf 'claude'; fi
      else
        printf 'auto'
      fi
      ;;
    *)
      echo "ERROR: invalid provider '$requested'." >&2
      return 2
      ;;
  esac
}

IMPLEMENTER="$(choose_provider "${MIZZY_IMPLEMENTER:-auto}" implementer)"
REVIEW_REQUESTED="${MIZZY_REVIEWER:-auto}"
case "$REVIEW_REQUESTED" in
  auto)
    if [[ "$IMPLEMENTER" == "codex" && "$has_claude" -eq 1 ]]; then
      REVIEWER="claude"
    elif [[ "$IMPLEMENTER" == "claude" && "$has_codex" -eq 1 ]]; then
      REVIEWER="codex"
    else
      REVIEWER="same"
    fi
    ;;
  same) REVIEWER="same" ;;
  codex|claude)
    REVIEWER="$(choose_provider "$REVIEW_REQUESTED" reviewer)"
    ;;
  *)
    echo "ERROR: invalid reviewer '$REVIEW_REQUESTED'." >&2
    exit 2
    ;;
esac
if [[ "$REVIEWER" == "same" ]]; then
  REVIEWER="$IMPLEMENTER"
fi
if [[ "$REVIEWER" == "$IMPLEMENTER" ]]; then
  echo "NOTICE: reviewer uses the same provider in a separate read-only session; independent provider review is not available."
fi
if [[ "$CRITICAL_TASK" -eq 1 && "$REVIEWER" == "$IMPLEMENTER" ]]; then
  echo "BLOCKED: critical tasks require a separate Codex or Claude reviewer. Configure an independent provider before starting work." >&2
  exit 2
fi

VERIFY_MODE="${MIZZY_VERIFY:-targeted}"
if [[ "$VERIFY_MODE" != "targeted" && "$VERIFY_MODE" != "full" ]]; then
  echo "ERROR: MIZZY_VERIFY must be 'targeted' or 'full'." >&2
  exit 2
fi
if [[ "$CRITICAL_TASK" -eq 1 && "$VERIFY_MODE" != "full" ]]; then
  echo "ROUTE: critical task overrides MIZZY_VERIFY=$VERIFY_MODE; using full verification."
  VERIFY_MODE="full"
fi
if [[ "$VERIFY_MODE" == "full" && "${MIZZY_RUN_SUPABASE_TESTS:-0}" != "1" ]]; then
  echo "ROUTE: full verification enables local Supabase DB tests."
  MIZZY_RUN_SUPABASE_TESTS=1
fi
if [[ "$VERIFY_MODE" == "full" ]] && ! command -v gitleaks >/dev/null 2>&1; then
  echo "ERROR: full mode requires the local 'gitleaks' CLI. Install/configure it before starting agents." >&2
  exit 2
fi
if [[ "${MIZZY_RUN_SUPABASE_TESTS:-0}" == "1" ]]; then
  command -v supabase >/dev/null 2>&1 || {
    echo "ERROR: Supabase tests were requested but the Supabase CLI is missing." >&2
    exit 2
  }
  command -v docker >/dev/null 2>&1 || {
    echo "ERROR: Supabase tests were requested but Docker is missing." >&2
    exit 2
  }
  docker info >/dev/null 2>&1 || {
    echo "ERROR: Docker is not ready; start the local container engine before agent execution." >&2
    exit 2
  }
fi
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_BASE="$ROOT/.agent-runs/${STAMP}-${TASK_SLUG}"
mkdir -p "$ROOT/.agent-runs"
RUN_DIR="$(mktemp -d "${RUN_BASE}.XXXXXX")"
CHECK_FAILED=0
CHECK_SUMMARY="$RUN_DIR/verification-summary.txt"

cat > "$RUN_DIR/task.md" <<TASK
# Task
$TASK_DESCRIPTION

# Run context
- Repository: Mizzy independent Android POS.
- Branch: $BRANCH
- Task slug: $TASK_SLUG
- Verify mode: $VERIFY_MODE
- Relevant rules: AGENT.md, AGENTS.md, CLAUDE.md, docs/agent-orchestration.md.
TASK

make_implementer_prompt() {
  local attempt="$1"
  local prior_context="$2"
  cat > "$RUN_DIR/implementer-prompt.md" <<PROMPT
You are the single write-capable implementer for the Mizzy Android POS repository.
Read AGENT.md, AGENTS.md and docs/agent-orchestration.md first.
Implement only the task below in this feature branch. Do not commit, push, merge, deploy,
provision services, modify other repositories, or alter production data. Do not weaken
security or hide failed tests. Keep the change small and add/update tests.
Inspect only relevant adjacent code. Never put secrets or customer data in output.
Run focused checks if practical, but report the exact commands and outcomes.
Return: changed paths, acceptance-criteria evidence, tests actually run, residual risks,
and a first-line verdict of PASS, CHANGES_REQUIRED, or BLOCKED.

Attempt: $attempt of $MAX_ATTEMPTS

$TASK_DESCRIPTION

$prior_context
PROMPT
}

run_agent() {
  local provider="$1"
  local role="$2"
  local prompt_file="$3"
  local log_file="$4"
  local final_file="$5"

  echo
  echo "=== ${role}: provider=${provider} ==="
  if [[ "$provider" == "codex" ]]; then
    local sandbox="workspace-write"
    [[ "$role" == "reviewer" ]] && sandbox="read-only"
    if codex exec --sandbox "$sandbox" --output-last-message "$final_file" - < "$prompt_file" 2>&1 | tee "$log_file"; then
      return 0
    else
      local status=$?
      echo "Agent command failed with exit code $status; see $log_file" | tee -a "$log_file"
      return "$status"
    fi
  fi

  local permission="acceptEdits"
  [[ "$role" == "reviewer" ]] && permission="plan"
  if claude -p --permission-mode "$permission" --max-turns "$MAX_TURNS" --output-format text "$(cat "$prompt_file")" 2>&1 | tee "$log_file"; then
    cp "$log_file" "$final_file"
    return 0
  else
    local status=$?
    echo "Agent command failed with exit code $status; see $log_file" | tee -a "$log_file"
    cp "$log_file" "$final_file"
    return "$status"
  fi
}

run_check() {
  local label="$1"
  shift
  echo "--- $label: $*"
  if "$@" 2>&1 | tee "$RUN_DIR/${label}.log"; then
    printf 'PASS: %s\n' "$label" | tee -a "$CHECK_SUMMARY"
  else
    local status=$?
    CHECK_FAILED=1
    printf 'FAIL: %s (exit %s)\n' "$label" "$status" | tee -a "$CHECK_SUMMARY"
  fi
}

run_verification() {
  CHECK_FAILED=0
  : > "$CHECK_SUMMARY"
  run_check diff-check git diff --check
  run_check dart-format dart format --output=none --set-exit-if-changed lib test
  run_check flutter-analyze flutter analyze

  if [[ "$VERIFY_MODE" == "full" ]]; then
    run_check flutter-tests flutter test
    run_check android-debug-apk flutter build apk --debug
    run_check android-apk-checksum sha256sum build/app/outputs/flutter-apk/app-debug.apk
    run_check gitleaks-working-tree gitleaks dir --redact --no-banner .
    run_check gitleaks-history gitleaks git --redact
  elif [[ -n "${MIZZY_TARGET_TEST:-}" ]]; then
    run_check focused-flutter-test flutter test "$MIZZY_TARGET_TEST"
  else
    # Fast path: execute changed test files, including newly created untracked
    # tests. Fall back to the full suite when no existing test file changed.
    mapfile -t existing_tests < <(mizzy_changed_test_files)
    if (( ${#existing_tests[@]} > 0 )); then
      local test_index=0
      for test_file in "${existing_tests[@]}"; do
        ((test_index += 1))
        run_check "focused-flutter-test-${test_index}" flutter test "$test_file"
      done
    else
      run_check flutter-tests flutter test
    fi
  fi

  if [[ "${MIZZY_RUN_SUPABASE_TESTS:-0}" == "1" ]]; then
    run_check supabase-local-tests supabase test db
  fi
}

extract_verdict() {
  local file="$1"
  local first_line=""
  if [[ -f "$file" ]]; then
    IFS= read -r first_line < "$file" || true
  fi
  case "$first_line" in
    "VERDICT: PASS") printf 'PASS' ;;
    "VERDICT: CHANGES_REQUIRED") printf 'CHANGES_REQUIRED' ;;
    "VERDICT: BLOCKED") printf 'BLOCKED' ;;
    *) printf 'MISSING' ;;
  esac
}

make_reviewer_prompt() {
  local attempt="$1"
  cat > "$RUN_DIR/reviewer-prompt.md" <<PROMPT
You are a strictly READ-ONLY independent reviewer. Read AGENT.md and docs/agent-orchestration.md.
Do not edit files, run mutating commands, commit, push, or change settings.
Review the full uncommitted diff against HEAD, the relevant tests, and these logs:
- $CHECK_SUMMARY
- Files in $RUN_DIR

Task and acceptance criteria:
$TASK_DESCRIPTION

Review correctness, missing tests, branch/tenant scope, money/idempotency, error states,
security, regressions, style, and scope. Cite file:line for each actionable finding.
Do not report a test passed unless the log explicitly says it did.
On the FIRST line output exactly one:
VERDICT: PASS
VERDICT: CHANGES_REQUIRED
VERDICT: BLOCKED
Then provide severity-ranked findings, evidence and a short rationale. If verification logs
show infrastructure/tooling blockers, say so explicitly instead of inferring code failure.
Review pass: $attempt
PROMPT
}

attempt=1
prior_context=""
final_verdict="BLOCKED"
while (( attempt <= MAX_ATTEMPTS )); do
  IMPLEMENTER_FAILED=0
  REVIEWER_FAILED=0
  make_implementer_prompt "$attempt" "$prior_context"
  if ! run_agent "$IMPLEMENTER" implementer "$RUN_DIR/implementer-prompt.md" "$RUN_DIR/implementer-${attempt}.log" "$RUN_DIR/implementer-${attempt}-final.txt"; then
    IMPLEMENTER_FAILED=1
    prior_context="The previous implementer process exited non-zero. Inspect $RUN_DIR/implementer-${attempt}.log; diagnose before modifying further."
  fi

  echo
  echo "=== Verification attempt $attempt / $MAX_ATTEMPTS ==="
  run_verification

  make_reviewer_prompt "$attempt"
  if ! run_agent "$REVIEWER" reviewer "$RUN_DIR/reviewer-prompt.md" "$RUN_DIR/reviewer-${attempt}.log" "$RUN_DIR/reviewer-${attempt}-final.txt"; then
    REVIEWER_FAILED=1
    echo "Reviewer process failed. Review evidence is incomplete." | tee -a "$CHECK_SUMMARY"
  fi
  IMPLEMENTER_VERDICT="$(extract_verdict "$RUN_DIR/implementer-${attempt}-final.txt")"
  final_verdict="$(extract_verdict "$RUN_DIR/reviewer-${attempt}-final.txt")"
  if [[ "$IMPLEMENTER_VERDICT" != "PASS" ]]; then
    echo "Implementer verdict was $IMPLEMENTER_VERDICT; an explicit first-line VERDICT: PASS is required." | tee -a "$CHECK_SUMMARY"
  fi

  if [[ "$CHECK_FAILED" -eq 0 && "$IMPLEMENTER_VERDICT" == "PASS" && "$final_verdict" == "PASS" && "$IMPLEMENTER_FAILED" -eq 0 && "$REVIEWER_FAILED" -eq 0 ]]; then
    if [[ "$CRITICAL_TASK" -eq 1 && "$REVIEWER" == "$IMPLEMENTER" ]]; then
      echo "BLOCKED: local checks completed, but critical work requires an independent cross-provider reviewer. See $RUN_DIR."
      exit 1
    fi
    echo
    if [[ "$REVIEWER" == "$IMPLEMENTER" ]]; then
      echo "PASS WITH LIMITATION: local verification passed; review used the same provider in read-only mode, not an independent cross-provider reviewer."
    else
      echo "PASS: local verification and independent cross-provider review completed."
    fi
    echo "No GitHub write/merge/deploy was performed."
    echo "Evidence folder: $RUN_DIR"
    exit 0
  fi

  if [[ "$final_verdict" == "BLOCKED" && "$CHECK_FAILED" -eq 0 ]]; then
    echo "BLOCKED: reviewer could not verify the change. See $RUN_DIR."
    exit 1
  fi

  if (( attempt == MAX_ATTEMPTS )); then
    echo "STOP: reached $MAX_ATTEMPTS distinct attempts. No commit/push/merge/deploy was performed."
    echo "Last reviewer verdict: $final_verdict"
    echo "Verification summary:"
    cat "$CHECK_SUMMARY"
    echo "Evidence folder: $RUN_DIR"
    exit 1
  fi

  prior_context="Previous attempt $attempt did not pass. Read the implementation/reviewer logs and verification summary in $RUN_DIR. Address only actionable code/test findings. If the blocker is runner/dependency availability or another infrastructure issue, do not invent a code fix. Prior summary:
$(cat "$CHECK_SUMMARY" 2>/dev/null || true)
Reviewer output:
$(cat "$RUN_DIR/reviewer-${attempt}-final.txt" 2>/dev/null || true)
"
  ((attempt += 1))
done
