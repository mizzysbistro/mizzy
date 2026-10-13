#!/usr/bin/env bash
# End-to-end coordinator test using deterministic fake CLIs; no model API or network.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEMP_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

FIXTURE="$TEMP_ROOT/mizzy-fixture"
FAKE_BIN="$TEMP_ROOT/fake-bin"
mkdir -p "$FIXTURE/scripts" "$FIXTURE/docs" "$FIXTURE/test" "$FAKE_BIN"
cp "$ROOT/scripts/mizzy-agent-loop.sh" "$FIXTURE/scripts/"
cp "$ROOT/scripts/mizzy-agent-loop-lib.sh" "$FIXTURE/scripts/"
cp "$ROOT/AGENT.md" "$ROOT/AGENTS.md" "$ROOT/CLAUDE.md" "$FIXTURE/"
cp "$ROOT/docs/agent-orchestration.md" "$FIXTURE/docs/"
cp "$ROOT/.gitignore" "$FIXTURE/"
git -C "$FIXTURE" init -q -b feature/agent-e2e-smoke
git -C "$FIXTURE" config user.name "Mizzy Agent Loop Test"
git -C "$FIXTURE" config user.email "mizzy-agent-loop-test@example.invalid"
git -C "$FIXTURE" remote add origin https://github.com/mizzysbistro/mizzy.git
git -C "$FIXTURE" add .
git -C "$FIXTURE" commit -qm "fixture: safe loop harness"

cat > "$FAKE_BIN/dart" <<'DART'
#!/usr/bin/env bash
echo "FAKE DART PASS: $*"
exit 0
DART
cat > "$FAKE_BIN/flutter" <<'FLUTTER'
#!/usr/bin/env bash
echo "FAKE FLUTTER PASS: $*"
printf 'flutter:%s\n' "$*" >> "$MIZZY_FAKE_CHECK_LOG"
exit 0
FLUTTER
cat > "$FAKE_BIN/gitleaks" <<'GITLEAKS'
#!/usr/bin/env bash
echo "FAKE GITLEAKS PASS: $*"
printf 'gitleaks:%s\n' "$*" >> "$MIZZY_FAKE_CHECK_LOG"
exit 0
GITLEAKS
cat > "$FAKE_BIN/sha256sum" <<'SHA256'
#!/usr/bin/env bash
echo "FAKE SHA256 PASS: $*"
printf 'sha256sum:%s\n' "$*" >> "$MIZZY_FAKE_CHECK_LOG"
exit 0
SHA256
cat > "$FAKE_BIN/supabase" <<'SUPABASE'
#!/usr/bin/env bash
echo "FAKE SUPABASE PASS: $*"
printf 'supabase:%s\n' "$*" >> "$MIZZY_FAKE_CHECK_LOG"
exit 0
SUPABASE
cat > "$FAKE_BIN/docker" <<'DOCKER'
#!/usr/bin/env bash
echo "FAKE DOCKER PASS: $*"
printf 'docker:%s\n' "$*" >> "$MIZZY_FAKE_CHECK_LOG"
exit 0
DOCKER
cat > "$FAKE_BIN/codex" <<'CODEX'
#!/usr/bin/env bash
set -Eeuo pipefail
sandbox=""
last_message=""
while (( $# > 0 )); do
  case "$1" in
    --sandbox) sandbox="$2"; shift 2 ;;
    --output-last-message) last_message="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cat >/dev/null
[[ -n "$last_message" ]] || { echo "missing output-last-message path" >&2; exit 41; }
case "$sandbox" in
  workspace-write)
    message="Stub implementer completed safely."
    verdict="${MIZZY_FAKE_IMPLEMENTER_VERDICT:-PASS}"
    output_prefix=""
    ;;
  read-only)
    message="Stub read-only reviewer found no issues."
    verdict="PASS"
    output_prefix="${MIZZY_FAKE_REVIEWER_PREFIX:-}"
    ;;
  *) echo "unexpected Codex sandbox: $sandbox" >&2; exit 42 ;;
esac
if [[ -n "$output_prefix" ]]; then
  printf '%s\n' "$output_prefix" > "$last_message"
else
  : > "$last_message"
fi
printf 'VERDICT: %s\n%s\n' "$verdict" "$message" >> "$last_message"
cat "$last_message"
printf 'codex:%s\n' "$sandbox" >> "$MIZZY_FAKE_AGENT_LOG"
CODEX
cat > "$FAKE_BIN/claude" <<'CLAUDE'
#!/usr/bin/env bash
set -Eeuo pipefail
permission=""
while (( $# > 0 )); do
  case "$1" in
    --permission-mode) permission="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$permission" in
  acceptEdits) message="Stub Claude implementer completed safely." ;;
  plan) message="Stub Claude read-only reviewer found no issues." ;;
  *) echo "unexpected Claude permission mode: $permission" >&2; exit 43 ;;
esac
printf 'VERDICT: PASS\n%s\n' "$message"
printf 'claude:%s\n' "$permission" >> "$MIZZY_FAKE_AGENT_LOG"
CLAUDE
chmod +x "$FAKE_BIN/"*

export MIZZY_FAKE_AGENT_LOG="$TEMP_ROOT/agent-calls.log"
export MIZZY_FAKE_CHECK_LOG="$TEMP_ROOT/check-calls.log"
: > "$MIZZY_FAKE_CHECK_LOG"
export PATH="$FAKE_BIN:$PATH"

# Low-risk task uses targeted verification and labels same-provider review honestly.
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=same bash scripts/mizzy-agent-loop.sh ui-copy "Adjust button spacing" 2>&1)"; then
  :
else
  echo "$output" >&2
  fail "low-risk same-provider loop unexpectedly failed"
fi
grep -q "PASS WITH LIMITATION" <<< "$output" ||
  fail "same-provider outcome did not disclose its limitation"
grep -q '^codex:workspace-write$' "$MIZZY_FAKE_AGENT_LOG" ||
  fail "Codex implementer did not use workspace-write"
grep -q '^codex:read-only$' "$MIZZY_FAKE_AGENT_LOG" ||
  fail "Codex reviewer did not use read-only"
if grep -q '^flutter:build apk --debug$' "$MIZZY_FAKE_CHECK_LOG"; then
  fail "low-risk task unexpectedly ran a critical full-build gate"
fi
if grep -q '^supabase:test db$' "$MIZZY_FAKE_CHECK_LOG"; then
  fail "low-risk task unexpectedly forced local Supabase tests"
fi

# Explicit full mode should add a debug build, secret scans, and local Supabase tests.
: > "$MIZZY_FAKE_CHECK_LOG"
if output="$(cd "$FIXTURE" && MIZZY_VERIFY=full MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=claude bash scripts/mizzy-agent-loop.sh ui-copy "Adjust button spacing" 2>&1)"; then
  :
else
  echo "$output" >&2
  fail "explicit full verification unexpectedly failed"
fi
grep -q "full verification enables local Supabase DB tests" <<< "$output" ||
  fail "full mode did not enable local Supabase tests"
grep -q '^flutter:build apk --debug$' "$MIZZY_FAKE_CHECK_LOG" ||
  fail "full mode did not build the debug APK"
grep -q '^supabase:test db$' "$MIZZY_FAKE_CHECK_LOG" ||
  fail "full mode did not run local Supabase tests"

# Critical tasks without an independent reviewer must fail before calling any agents.
: > "$MIZZY_FAKE_CHECK_LOG"
calls_before="$(wc -l < "$MIZZY_FAKE_AGENT_LOG")"
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=same bash scripts/mizzy-agent-loop.sh payment-refund "Validate refund workflow" 2>&1)"; then
  fail "critical task incorrectly accepted same-provider review"
fi
grep -q "BLOCKED: critical tasks require a separate Codex or Claude reviewer" <<< "$output" ||
  fail "critical task did not fail fast when its independent reviewer was missing"
calls_after="$(wc -l < "$MIZZY_FAKE_AGENT_LOG")"
[[ "$calls_before" == "$calls_after" ]] ||
  fail "critical task invoked an agent before verifying reviewer availability"
if grep -Eq '^(flutter:|gitleaks:|supabase:test db)' "$MIZZY_FAKE_CHECK_LOG"; then
  fail "critical task ran verification tasks after failing fast for missing reviewer"
fi

# An independent provider unlocks the critical full verification lane.
: > "$MIZZY_FAKE_CHECK_LOG"
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=claude bash scripts/mizzy-agent-loop.sh payment-refund "Validate refund workflow" 2>&1)"; then
  :
else
  echo "$output" >&2
  fail "critical cross-provider loop unexpectedly failed"
fi
grep -q "PASS: local verification and independent cross-provider review completed" <<< "$output" ||
  fail "critical cross-provider PASS was not reported"
grep -q '^claude:plan

# A successful CLI exit and passing reviewer must not override a non-PASS implementer verdict.
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=same MIZZY_FAKE_IMPLEMENTER_VERDICT=CHANGES_REQUIRED bash scripts/mizzy-agent-loop.sh ui-copy "Adjust button spacing" 2>&1)"; then
  fail "coordinator accepted CHANGES_REQUIRED implementer verdict"
fi
grep -q "Implementer verdict was CHANGES_REQUIRED" <<< "$output" ||
  fail "non-PASS implementer verdict was not surfaced"
grep -q "STOP: reached 3 distinct attempts" <<< "$output" ||
  fail "non-PASS implementer verdict did not exhaust bounded retries"

# PASS below a non-verdict first line must not satisfy strict parsing.
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=same MIZZY_FAKE_REVIEWER_PREFIX="Untrusted preface" bash scripts/mizzy-agent-loop.sh ui-copy "Adjust button spacing" 2>&1)"; then
  fail "coordinator accepted reviewer output without a verdict on line one"
fi
grep -q "Last reviewer verdict: MISSING" <<< "$output" ||
  fail "malformed reviewer first line was not rejected"

# Invalid configuration must fail before any agent invocation.
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=same MIZZY_AGENT_MAX_TURNS=0 bash scripts/mizzy-agent-loop.sh ui-copy "Adjust button spacing" 2>&1)"; then
  fail "invalid turn limit was accepted"
fi
grep -q "MIZZY_AGENT_MAX_TURNS must be a positive integer" <<< "$output" ||
  fail "invalid turn-limit diagnostic was missing"

# Wrong repository origin must be rejected before any agent invocation.
calls_before="$(wc -l < "$MIZZY_FAKE_AGENT_LOG")"
git -C "$FIXTURE" remote set-url origin https://github.com/mizzysbistro/bistro.git
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=same bash scripts/mizzy-agent-loop.sh ui-copy "Adjust button spacing" 2>&1)"; then
  fail "launcher accepted a sibling repository origin"
fi
grep -q "origin remote must point to mizzysbistro/mizzy on GitHub" <<< "$output" ||
  fail "wrong-origin diagnostic was missing"
calls_after="$(wc -l < "$MIZZY_FAKE_AGENT_LOG")"
[[ "$calls_before" == "$calls_after" ]] ||
  fail "an agent was invoked with the wrong origin"

echo "PASS: coordinator, routing, explicit verdicts, and verification gates using fake CLIs only"
 "$MIZZY_FAKE_AGENT_LOG" ||
  fail "Claude reviewer did not use plan mode"

grep -q '^flutter:build apk --debug

# A successful CLI exit and passing reviewer must not override a non-PASS implementer verdict.
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=same MIZZY_FAKE_IMPLEMENTER_VERDICT=CHANGES_REQUIRED bash scripts/mizzy-agent-loop.sh ui-copy "Adjust button spacing" 2>&1)"; then
  fail "coordinator accepted CHANGES_REQUIRED implementer verdict"
fi
grep -q "Implementer verdict was CHANGES_REQUIRED" <<< "$output" ||
  fail "non-PASS implementer verdict was not surfaced"
grep -q "STOP: reached 3 distinct attempts" <<< "$output" ||
  fail "non-PASS implementer verdict did not exhaust bounded retries"

# PASS below a non-verdict first line must not satisfy strict parsing.
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=same MIZZY_FAKE_REVIEWER_PREFIX="Untrusted preface" bash scripts/mizzy-agent-loop.sh ui-copy "Adjust button spacing" 2>&1)"; then
  fail "coordinator accepted reviewer output without a verdict on line one"
fi
grep -q "Last reviewer verdict: MISSING" <<< "$output" ||
  fail "malformed reviewer first line was not rejected"

# Invalid configuration must fail before any agent invocation.
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=same MIZZY_AGENT_MAX_TURNS=0 bash scripts/mizzy-agent-loop.sh ui-copy "Adjust button spacing" 2>&1)"; then
  fail "invalid turn limit was accepted"
fi
grep -q "MIZZY_AGENT_MAX_TURNS must be a positive integer" <<< "$output" ||
  fail "invalid turn-limit diagnostic was missing"

# Wrong repository origin must be rejected before any agent invocation.
calls_before="$(wc -l < "$MIZZY_FAKE_AGENT_LOG")"
git -C "$FIXTURE" remote set-url origin https://github.com/mizzysbistro/bistro.git
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=same bash scripts/mizzy-agent-loop.sh ui-copy "Adjust button spacing" 2>&1)"; then
  fail "launcher accepted a sibling repository origin"
fi
grep -q "origin remote must point to mizzysbistro/mizzy on GitHub" <<< "$output" ||
  fail "wrong-origin diagnostic was missing"
calls_after="$(wc -l < "$MIZZY_FAKE_AGENT_LOG")"
[[ "$calls_before" == "$calls_after" ]] ||
  fail "an agent was invoked with the wrong origin"

echo "PASS: coordinator, routing, explicit verdicts, and verification gates using fake CLIs only"
 "$MIZZY_FAKE_CHECK_LOG" ||
  fail "critical cross-provider route did not run Android debug build"
grep -q '^sha256sum:build/app/outputs/flutter-apk/app-debug.apk

# A successful CLI exit and passing reviewer must not override a non-PASS implementer verdict.
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=same MIZZY_FAKE_IMPLEMENTER_VERDICT=CHANGES_REQUIRED bash scripts/mizzy-agent-loop.sh ui-copy "Adjust button spacing" 2>&1)"; then
  fail "coordinator accepted CHANGES_REQUIRED implementer verdict"
fi
grep -q "Implementer verdict was CHANGES_REQUIRED" <<< "$output" ||
  fail "non-PASS implementer verdict was not surfaced"
grep -q "STOP: reached 3 distinct attempts" <<< "$output" ||
  fail "non-PASS implementer verdict did not exhaust bounded retries"

# PASS below a non-verdict first line must not satisfy strict parsing.
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=same MIZZY_FAKE_REVIEWER_PREFIX="Untrusted preface" bash scripts/mizzy-agent-loop.sh ui-copy "Adjust button spacing" 2>&1)"; then
  fail "coordinator accepted reviewer output without a verdict on line one"
fi
grep -q "Last reviewer verdict: MISSING" <<< "$output" ||
  fail "malformed reviewer first line was not rejected"

# Invalid configuration must fail before any agent invocation.
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=same MIZZY_AGENT_MAX_TURNS=0 bash scripts/mizzy-agent-loop.sh ui-copy "Adjust button spacing" 2>&1)"; then
  fail "invalid turn limit was accepted"
fi
grep -q "MIZZY_AGENT_MAX_TURNS must be a positive integer" <<< "$output" ||
  fail "invalid turn-limit diagnostic was missing"

# Wrong repository origin must be rejected before any agent invocation.
calls_before="$(wc -l < "$MIZZY_FAKE_AGENT_LOG")"
git -C "$FIXTURE" remote set-url origin https://github.com/mizzysbistro/bistro.git
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=same bash scripts/mizzy-agent-loop.sh ui-copy "Adjust button spacing" 2>&1)"; then
  fail "launcher accepted a sibling repository origin"
fi
grep -q "origin remote must point to mizzysbistro/mizzy on GitHub" <<< "$output" ||
  fail "wrong-origin diagnostic was missing"
calls_after="$(wc -l < "$MIZZY_FAKE_AGENT_LOG")"
[[ "$calls_before" == "$calls_after" ]] ||
  fail "an agent was invoked with the wrong origin"

echo "PASS: coordinator, routing, explicit verdicts, and verification gates using fake CLIs only"
 "$MIZZY_FAKE_CHECK_LOG" ||
  fail "critical cross-provider route did not record APK SHA-256"
grep -q '^gitleaks:dir --redact --no-banner .

# A successful CLI exit and passing reviewer must not override a non-PASS implementer verdict.
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=same MIZZY_FAKE_IMPLEMENTER_VERDICT=CHANGES_REQUIRED bash scripts/mizzy-agent-loop.sh ui-copy "Adjust button spacing" 2>&1)"; then
  fail "coordinator accepted CHANGES_REQUIRED implementer verdict"
fi
grep -q "Implementer verdict was CHANGES_REQUIRED" <<< "$output" ||
  fail "non-PASS implementer verdict was not surfaced"
grep -q "STOP: reached 3 distinct attempts" <<< "$output" ||
  fail "non-PASS implementer verdict did not exhaust bounded retries"

# PASS below a non-verdict first line must not satisfy strict parsing.
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=same MIZZY_FAKE_REVIEWER_PREFIX="Untrusted preface" bash scripts/mizzy-agent-loop.sh ui-copy "Adjust button spacing" 2>&1)"; then
  fail "coordinator accepted reviewer output without a verdict on line one"
fi
grep -q "Last reviewer verdict: MISSING" <<< "$output" ||
  fail "malformed reviewer first line was not rejected"

# Invalid configuration must fail before any agent invocation.
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=same MIZZY_AGENT_MAX_TURNS=0 bash scripts/mizzy-agent-loop.sh ui-copy "Adjust button spacing" 2>&1)"; then
  fail "invalid turn limit was accepted"
fi
grep -q "MIZZY_AGENT_MAX_TURNS must be a positive integer" <<< "$output" ||
  fail "invalid turn-limit diagnostic was missing"

# Wrong repository origin must be rejected before any agent invocation.
calls_before="$(wc -l < "$MIZZY_FAKE_AGENT_LOG")"
git -C "$FIXTURE" remote set-url origin https://github.com/mizzysbistro/bistro.git
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=same bash scripts/mizzy-agent-loop.sh ui-copy "Adjust button spacing" 2>&1)"; then
  fail "launcher accepted a sibling repository origin"
fi
grep -q "origin remote must point to mizzysbistro/mizzy on GitHub" <<< "$output" ||
  fail "wrong-origin diagnostic was missing"
calls_after="$(wc -l < "$MIZZY_FAKE_AGENT_LOG")"
[[ "$calls_before" == "$calls_after" ]] ||
  fail "an agent was invoked with the wrong origin"

echo "PASS: coordinator, routing, explicit verdicts, and verification gates using fake CLIs only"
 "$MIZZY_FAKE_CHECK_LOG" ||
  fail "critical cross-provider route did not scan the worktree"
grep -q '^gitleaks:git --redact

# A successful CLI exit and passing reviewer must not override a non-PASS implementer verdict.
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=same MIZZY_FAKE_IMPLEMENTER_VERDICT=CHANGES_REQUIRED bash scripts/mizzy-agent-loop.sh ui-copy "Adjust button spacing" 2>&1)"; then
  fail "coordinator accepted CHANGES_REQUIRED implementer verdict"
fi
grep -q "Implementer verdict was CHANGES_REQUIRED" <<< "$output" ||
  fail "non-PASS implementer verdict was not surfaced"
grep -q "STOP: reached 3 distinct attempts" <<< "$output" ||
  fail "non-PASS implementer verdict did not exhaust bounded retries"

# PASS below a non-verdict first line must not satisfy strict parsing.
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=same MIZZY_FAKE_REVIEWER_PREFIX="Untrusted preface" bash scripts/mizzy-agent-loop.sh ui-copy "Adjust button spacing" 2>&1)"; then
  fail "coordinator accepted reviewer output without a verdict on line one"
fi
grep -q "Last reviewer verdict: MISSING" <<< "$output" ||
  fail "malformed reviewer first line was not rejected"

# Invalid configuration must fail before any agent invocation.
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=same MIZZY_AGENT_MAX_TURNS=0 bash scripts/mizzy-agent-loop.sh ui-copy "Adjust button spacing" 2>&1)"; then
  fail "invalid turn limit was accepted"
fi
grep -q "MIZZY_AGENT_MAX_TURNS must be a positive integer" <<< "$output" ||
  fail "invalid turn-limit diagnostic was missing"

# Wrong repository origin must be rejected before any agent invocation.
calls_before="$(wc -l < "$MIZZY_FAKE_AGENT_LOG")"
git -C "$FIXTURE" remote set-url origin https://github.com/mizzysbistro/bistro.git
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=same bash scripts/mizzy-agent-loop.sh ui-copy "Adjust button spacing" 2>&1)"; then
  fail "launcher accepted a sibling repository origin"
fi
grep -q "origin remote must point to mizzysbistro/mizzy on GitHub" <<< "$output" ||
  fail "wrong-origin diagnostic was missing"
calls_after="$(wc -l < "$MIZZY_FAKE_AGENT_LOG")"
[[ "$calls_before" == "$calls_after" ]] ||
  fail "an agent was invoked with the wrong origin"

echo "PASS: coordinator, routing, explicit verdicts, and verification gates using fake CLIs only"
 "$MIZZY_FAKE_CHECK_LOG" ||
  fail "critical cross-provider route did not scan Git history"
grep -q '^supabase:test db

# A successful CLI exit and passing reviewer must not override a non-PASS implementer verdict.
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=same MIZZY_FAKE_IMPLEMENTER_VERDICT=CHANGES_REQUIRED bash scripts/mizzy-agent-loop.sh ui-copy "Adjust button spacing" 2>&1)"; then
  fail "coordinator accepted CHANGES_REQUIRED implementer verdict"
fi
grep -q "Implementer verdict was CHANGES_REQUIRED" <<< "$output" ||
  fail "non-PASS implementer verdict was not surfaced"
grep -q "STOP: reached 3 distinct attempts" <<< "$output" ||
  fail "non-PASS implementer verdict did not exhaust bounded retries"

# PASS below a non-verdict first line must not satisfy strict parsing.
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=same MIZZY_FAKE_REVIEWER_PREFIX="Untrusted preface" bash scripts/mizzy-agent-loop.sh ui-copy "Adjust button spacing" 2>&1)"; then
  fail "coordinator accepted reviewer output without a verdict on line one"
fi
grep -q "Last reviewer verdict: MISSING" <<< "$output" ||
  fail "malformed reviewer first line was not rejected"

# Invalid configuration must fail before any agent invocation.
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=same MIZZY_AGENT_MAX_TURNS=0 bash scripts/mizzy-agent-loop.sh ui-copy "Adjust button spacing" 2>&1)"; then
  fail "invalid turn limit was accepted"
fi
grep -q "MIZZY_AGENT_MAX_TURNS must be a positive integer" <<< "$output" ||
  fail "invalid turn-limit diagnostic was missing"

# Wrong repository origin must be rejected before any agent invocation.
calls_before="$(wc -l < "$MIZZY_FAKE_AGENT_LOG")"
git -C "$FIXTURE" remote set-url origin https://github.com/mizzysbistro/bistro.git
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=same bash scripts/mizzy-agent-loop.sh ui-copy "Adjust button spacing" 2>&1)"; then
  fail "launcher accepted a sibling repository origin"
fi
grep -q "origin remote must point to mizzysbistro/mizzy on GitHub" <<< "$output" ||
  fail "wrong-origin diagnostic was missing"
calls_after="$(wc -l < "$MIZZY_FAKE_AGENT_LOG")"
[[ "$calls_before" == "$calls_after" ]] ||
  fail "an agent was invoked with the wrong origin"

echo "PASS: coordinator, routing, explicit verdicts, and verification gates using fake CLIs only"
 "$MIZZY_FAKE_CHECK_LOG" ||
  fail "critical cross-provider route did not run local Supabase tests"
grep -q '^docker:info

# A successful CLI exit and passing reviewer must not override a non-PASS implementer verdict.
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=same MIZZY_FAKE_IMPLEMENTER_VERDICT=CHANGES_REQUIRED bash scripts/mizzy-agent-loop.sh ui-copy "Adjust button spacing" 2>&1)"; then
  fail "coordinator accepted CHANGES_REQUIRED implementer verdict"
fi
grep -q "Implementer verdict was CHANGES_REQUIRED" <<< "$output" ||
  fail "non-PASS implementer verdict was not surfaced"
grep -q "STOP: reached 3 distinct attempts" <<< "$output" ||
  fail "non-PASS implementer verdict did not exhaust bounded retries"

# PASS below a non-verdict first line must not satisfy strict parsing.
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=same MIZZY_FAKE_REVIEWER_PREFIX="Untrusted preface" bash scripts/mizzy-agent-loop.sh ui-copy "Adjust button spacing" 2>&1)"; then
  fail "coordinator accepted reviewer output without a verdict on line one"
fi
grep -q "Last reviewer verdict: MISSING" <<< "$output" ||
  fail "malformed reviewer first line was not rejected"

# Invalid configuration must fail before any agent invocation.
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=same MIZZY_AGENT_MAX_TURNS=0 bash scripts/mizzy-agent-loop.sh ui-copy "Adjust button spacing" 2>&1)"; then
  fail "invalid turn limit was accepted"
fi
grep -q "MIZZY_AGENT_MAX_TURNS must be a positive integer" <<< "$output" ||
  fail "invalid turn-limit diagnostic was missing"

# Wrong repository origin must be rejected before any agent invocation.
calls_before="$(wc -l < "$MIZZY_FAKE_AGENT_LOG")"
git -C "$FIXTURE" remote set-url origin https://github.com/mizzysbistro/bistro.git
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=same bash scripts/mizzy-agent-loop.sh ui-copy "Adjust button spacing" 2>&1)"; then
  fail "launcher accepted a sibling repository origin"
fi
grep -q "origin remote must point to mizzysbistro/mizzy on GitHub" <<< "$output" ||
  fail "wrong-origin diagnostic was missing"
calls_after="$(wc -l < "$MIZZY_FAKE_AGENT_LOG")"
[[ "$calls_before" == "$calls_after" ]] ||
  fail "an agent was invoked with the wrong origin"

echo "PASS: coordinator, routing, explicit verdicts, and verification gates using fake CLIs only"
 "$MIZZY_FAKE_CHECK_LOG" ||
  fail "critical route did not verify Docker readiness"

# A successful CLI exit and passing reviewer must not override a non-PASS implementer verdict.
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=same MIZZY_FAKE_IMPLEMENTER_VERDICT=CHANGES_REQUIRED bash scripts/mizzy-agent-loop.sh ui-copy "Adjust button spacing" 2>&1)"; then
  fail "coordinator accepted CHANGES_REQUIRED implementer verdict"
fi
grep -q "Implementer verdict was CHANGES_REQUIRED" <<< "$output" ||
  fail "non-PASS implementer verdict was not surfaced"
grep -q "STOP: reached 3 distinct attempts" <<< "$output" ||
  fail "non-PASS implementer verdict did not exhaust bounded retries"

# PASS below a non-verdict first line must not satisfy strict parsing.
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=same MIZZY_FAKE_REVIEWER_PREFIX="Untrusted preface" bash scripts/mizzy-agent-loop.sh ui-copy "Adjust button spacing" 2>&1)"; then
  fail "coordinator accepted reviewer output without a verdict on line one"
fi
grep -q "Last reviewer verdict: MISSING" <<< "$output" ||
  fail "malformed reviewer first line was not rejected"

# Invalid configuration must fail before any agent invocation.
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=same MIZZY_AGENT_MAX_TURNS=0 bash scripts/mizzy-agent-loop.sh ui-copy "Adjust button spacing" 2>&1)"; then
  fail "invalid turn limit was accepted"
fi
grep -q "MIZZY_AGENT_MAX_TURNS must be a positive integer" <<< "$output" ||
  fail "invalid turn-limit diagnostic was missing"

# Wrong repository origin must be rejected before any agent invocation.
calls_before="$(wc -l < "$MIZZY_FAKE_AGENT_LOG")"
git -C "$FIXTURE" remote set-url origin https://github.com/mizzysbistro/bistro.git
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=same bash scripts/mizzy-agent-loop.sh ui-copy "Adjust button spacing" 2>&1)"; then
  fail "launcher accepted a sibling repository origin"
fi
grep -q "origin remote must point to mizzysbistro/mizzy on GitHub" <<< "$output" ||
  fail "wrong-origin diagnostic was missing"
calls_after="$(wc -l < "$MIZZY_FAKE_AGENT_LOG")"
[[ "$calls_before" == "$calls_after" ]] ||
  fail "an agent was invoked with the wrong origin"

echo "PASS: coordinator, routing, explicit verdicts, and verification gates using fake CLIs only"
