---
name: mizzy-smart-loop
description: Use when implementing, debugging, reviewing, or advancing any Mizzy P0-P6 task in a repository with Codex or Claude Code available.
---

# Mizzy Smart Agent Loop

Read `AGENT.md`, `AGENTS.md`, and `docs/agent-orchestration.md` before acting.

## Route the task
- Small, low-risk change: fast lane, one implementer, focused verification, reviewer if available.
- Feature or data logic: standard lane, focused tests plus independent read-only review and full PR checks.
- Auth, RLS, tenant/branch scope, payments, inventory, sync, migrations, or release: critical lane with explicit security review, negative tests, and full verification.
- Work only on the independent Mizzy repository. Never modify sibling POS repositories.

## Single-writer rule
Only one write-capable agent may work in a checkout at a time. Use Codex CLI as implementer and Claude Code as reviewer by default when both are installed; reverse the roles when configured. Reviewers are read-only. If a second provider is unavailable, record that peer review is missing and continue only within safe scope.

## Task contract
Before editing, define:
- Goal and non-goals.
- Two to five observable acceptance criteria.
- Exact in-scope paths and tests.
- Security/data invariants and a rollback strategy for risky changes.

Implement the smallest testable change. Prefer test-first defect work. Report only commands actually run and their exit status. Inspect the full diff and check the test logs independently.

## Strict completion gate
- The first line of both implementer and reviewer output must be exactly `VERDICT: PASS`, `VERDICT: CHANGES_REQUIRED`, or `VERDICT: BLOCKED`. The coordinator accepts success only when the first line is exactly `VERDICT: PASS` for both providers, every required command passes, and neither CLI exits nonzero. A successful CLI exit alone is never a task PASS.
- Codex implementer runs in `workspace-write`; Codex reviewer runs in `read-only`. Claude implementer runs in `acceptEdits`; Claude reviewer runs in `plan`. The separate reviewer must not edit.
- The launcher must verify origin is the independent `mizzysbistro/mizzy` repository. Never run in sibling POS repos.
- The fast test selector covers staged/unstaged tracked and untracked tests, filters deleted paths, and falls back to the full suite when no current test file changed. Critical tasks automatically upgrade to `MIZZY_VERIFY=full` and force local Supabase DB tests; the loop fails fast unless Gitleaks, Supabase CLI and Docker are available and Docker is ready. For noncritical PR/release work use `MIZZY_VERIFY=full` and opt in to local DB tests with `MIZZY_RUN_SUPABASE_TESTS=1`.

## Repair loop
1. Inspect current issue/PR/commit and relevant files.
2. Implement one small patch.
3. Run strict formatter, analyzer, and focused tests.
4. Request a read-only peer review and address material findings.
5. Run the full gate at PR boundaries or when the risk tier requires it.
6. Record commit, evidence, remaining risks, and next action in GitHub.
7. Retry no more than three distinct strategies. Repeating the same failing command without a new hypothesis is not progress.

## CI outage rule
If a workflow ends before any step starts and reports `runner_id: 0`, zero steps, and no logs, classify it as infrastructure blocked—not an application test failure. Retry one current-head run. If the same signature repeats, stop retrying and record the blocker; do not change repository visibility or enable paid runners without approval.

## Verification levels
- Focused: strict Dart format, `flutter analyze`, and the changed feature tests.
- Full PR: strict format, analysis, all Flutter tests, secret scan, local Supabase migration/pgTAP tests, Android debug APK and checksum, plus read-only peer review.
- Production: every applicable P0-P6 exit gate, live-device/install/upgrade evidence, data/financial reconciliation, backup/restore, and explicit release authorization.

## Local launcher
On a development machine with Git, Flutter/Dart and authenticated local agent CLIs, run:
`bash scripts/mizzy-agent-loop.sh <task-slug> "<task description>"`

The launcher requires a clean non-main feature branch, writes reports under ignored `.agent-runs/`, verifies locally, and never commits, pushes, merges, provisions services, or deploys.
