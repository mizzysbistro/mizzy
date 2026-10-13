#!/usr/bin/env bash
# End-to-end coordinator test with deterministic fake CLIs; no model API or network.
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
mkdir -p "$FIXTURE/scripts" "$FIXTURE/docs" "$FIXTURE/lib" "$FIXTURE/test" "$FAKE_BIN"
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
exit 0
FLUTTER
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
  workspace-write) message="Stub implementer completed safely." ;;
  read-only) message="Stub read-only reviewer found no issues." ;;
  *) echo "unexpected Codex sandbox: $sandbox" >&2; exit 42 ;;
esac
printf 'VERDICT: PASS\n%s\n' "$message" > "$last_message"
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
export PATH="$FAKE_BIN:$PATH"

# Low-risk task: same-provider review is allowed, explicitly read-only, and labeled.
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=same bash scripts/mizzy-agent-loop.sh ui-copy "Adjust button spacing" 2>&1)"; then
  :
else
  echo "$output" >&2
  fail "low-risk same-provider loop unexpectedly failed"
fi
grep -q "PASS WITH LIMITATION" <<< "$output" ||
  fail "same-provider outcome was not labeled with its limitation"
grep -q '^codex:workspace-write$' "$MIZZY_FAKE_AGENT_LOG" ||
  fail "Codex implementer was not invoked with workspace-write"
grep -q '^codex:read-only$' "$MIZZY_FAKE_AGENT_LOG" ||
  fail "Codex reviewer was not invoked with read-only sandbox"

# Critical work must not pass when only one provider is used.
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=same bash scripts/mizzy-agent-loop.sh payment-refund "Validate refund workflow" 2>&1)"; then
  fail "critical task incorrectly passed with same-provider review"
fi
grep -q "BLOCKED: local checks completed, but critical work requires an independent cross-provider reviewer" <<< "$output" ||
  fail "critical-task independent-review gate did not block"

# Critical work can pass the coordinator gate only with a second provider reviewer.
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=claude bash scripts/mizzy-agent-loop.sh payment-refund "Validate refund workflow" 2>&1)"; then
  :
else
  echo "$output" >&2
  fail "critical cross-provider loop unexpectedly failed"
fi
grep -q "PASS: local verification and independent cross-provider review completed" <<< "$output" ||
  fail "critical cross-provider pass was not reported"
grep -q '^claude:plan$' "$MIZZY_FAKE_AGENT_LOG" ||
  fail "Claude reviewer was not invoked in plan mode"

# Validate environment configuration early without running either fake agent.
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=same MIZZY_AGENT_MAX_TURNS=0 bash scripts/mizzy-agent-loop.sh ui-copy "Adjust button spacing" 2>&1)"; then
  fail "invalid MIZZY_AGENT_MAX_TURNS value was accepted"
fi
grep -q "MIZZY_AGENT_MAX_TURNS must be a positive integer" <<< "$output" ||
  fail "invalid turn-limit diagnostic was missing"

# The repository identity guard must stop before any provider invocation.
calls_before="$(wc -l < "$MIZZY_FAKE_AGENT_LOG")"
git -C "$FIXTURE" remote set-url origin https://github.com/mizzysbistro/bistro.git
if output="$(cd "$FIXTURE" && MIZZY_IMPLEMENTER=codex MIZZY_REVIEWER=same bash scripts/mizzy-agent-loop.sh ui-copy "Adjust button spacing" 2>&1)"; then
  fail "launcher accepted a sibling repository origin"
fi
grep -q "origin remote must point to mizzysbistro/mizzy on GitHub" <<< "$output" ||
  fail "wrong-origin diagnostic was missing"
calls_after="$(wc -l < "$MIZZY_FAKE_AGENT_LOG")"
[[ "$calls_before" == "$calls_after" ]] ||
  fail "agent was invoked despite the wrong repository origin"
git -C "$FIXTURE" remote set-url origin https://github.com/mizzysbistro/mizzy.git

echo "PASS: end-to-end coordinator gates with fake provider CLIs; no external agents or paid APIs invoked"
