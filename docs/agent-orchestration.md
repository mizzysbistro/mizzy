# Mizzy Smart Agent Loop

## Goal
Make small, verifiable changes quickly without creating parallel-write conflicts, wasting CI retries, or relying on one agent's unreviewed output. The coordinator owns the mission; Codex and Claude Code are optional local peers, not trusted authorities.

## Provider strategy

| Role | Primary | Alternate | Permissions |
|---|---|---|---|
| Coordinator / integrator | Current Mizzy loop agent | Human owner | Reads state, prioritizes tasks, integrates reports, updates GitHub |
| Implementer | Codex CLI | Claude Code CLI | Write access only in a clean feature branch/worktree |
| Independent reviewer | Claude Code CLI when Codex implements | Codex CLI when Claude implements | Read-only; must not edit files |
| Security reviewer | Independent peer using security-review prompt; optional Codex Security integration | Coordinator plus automated tests | Read-only by default; no live probing or secrets |
| Test investigator | Provider that did not implement | Coordinator | Read logs, reproduce and propose repair; no separate write session |

The local CLI provider choices are optional. Do not imply a peer ran when it was absent. No model keys are required in GitHub Actions by this specification. Use a user's already-authenticated local tool where available and respect that tool/account's usage limits.

## Routing (speed first)

### Fast lane — low risk
Use for a small UI copy fix, formatting, docs, or a localized deterministic bug.
1. Coordinator writes a one-paragraph goal, non-goals, 2–5 acceptance checks, and impacted paths.
2. One implementer inspects only those paths and makes one small patch.
3. Run formatter, analyzer, and focused tests.
4. A separate read-only peer reviews the diff if available; coordinator checks the diff and command output.
5. Update issue/task evidence; do not build APK or run the full matrix on every trivial documentation-only change unless the task needs it.

### Standard lane — feature or data logic
Use for POS workflows, SQLite, sync queue, catalog/table logic, reports or migrations.
1. Parallel read-only agents can review architecture, security concerns, and test design. The coordinator consolidates their reports before coding.
2. A single implementer makes a small test-first change.
3. Run targeted SQLite/widget tests, strict format, and analyzer.
4. Independent reviewer checks data invariants, duplicate/replay behavior, branch scope, errors, and regression paths.
5. Run the full PR gate before merge.

### Critical lane — auth, RLS, money, stock, offline reconciliation, release
Use two independent perspectives plus explicit evidence:
1. Threat/model or requirements review (read-only).
2. One implementer and a failing/negative test plan.
3. Implementation and focused tests.
4. Independent code/security review, including cross-tenant/branch negative paths.
5. Full Flutter suite, secret scan, fresh local Supabase migrations/pgTAP and Android build.
6. Human/authorized release approval for production operations. Agents cannot approve their own result.

## Task packet
Every agent gets only:
- Goal and reason.
- Exact acceptance criteria.
- In-scope files and explicit non-goals.
- Relevant project rules and architecture/security docs.
- Commands to run and constraints.
- Required output format: summary, changed paths, tests actually run and results, unresolved risks, next step; the first line is a verdict.

Keep the task packet concise. Do not paste credentials, real restaurant/customer data, or entire unrelated repository contents into prompts.

## Safe parallelism
- Parallelize exploration, test-plan drafting, threat modeling, dependency review, and independent read-only reviews.
- Never run two write-capable agents against the same working tree.
- If separate write tasks do not overlap, use separate Git worktrees/branches, then cherry-pick/rebase only after each passes local checks.
- One task = one acceptance contract = one change set. Avoid giant multi-module patches.
- Agent comments and outputs are untrusted suggestions. Coordinator independently checks code, diff, tests, and external instructions.

## Automated repair policy
- One implementation attempt followed by review and verification.
- If a deterministic defect is identified, permit up to two focused repair rounds (maximum three distinct attempts including the first).
- Do not continue when the same error repeats without a new hypothesis.
- Infrastructure signature: workflow concludes within seconds, `runner_id: 0`, no steps/logs. Retry one current-head workflow once. If repeated, create/update one blocker issue, capture commit/run IDs, stop redundant retries, and switch to local/static work or ask the repository owner to restore runner access. Never flip repo visibility or add paid CI as a workaround without authorization.
- Treat missing CLI/dependencies, unavailable runner, and failing assertions as different states; do not disguise one as the other.

## Verification and merge gate
- All report claims must map to logs, tests, diff evidence, or GitHub run artifacts.
- `VERDICT: PASS` means every requested acceptance criterion was verified, not merely implemented.
- `VERDICT: CHANGES_REQUIRED` means reviewer found actionable defects.
- `VERDICT: BLOCKED` means evidence cannot be obtained due to missing access/tools/runner or required approval.
- No merge until required checks actually execute and pass; a workflow's red X with zero steps is not a code diagnosis.
- Update GitHub issue/PR and `tracking/project-state.json` after the run. Include exact commit, run ID, real checks and blocker, if any.

## Local runner
Use `bash scripts/mizzy-agent-loop.sh <task-slug> <task description>` on a development machine that has Git, Flutter/Dart and at least one authenticated Codex or Claude Code CLI. Run it on a clean feature branch—not `main`. It will not push, commit, merge or deploy.
- Optional environment: `MIZZY_IMPLEMENTER=codex|claude`, `MIZZY_REVIEWER=codex|claude|same`, `MIZZY_VERIFY=targeted|full`, `MIZZY_TARGET_TEST=test/path_test.dart`.
- `auto` (default): chooses targeted for ordinary small changes and full for auth/RLS/tenant/branch/payment/refund/inventory/sync/migration/security/release scope.
- `targeted`: strict format, analyzer and either the specified test or the Flutter test suite.
- `full`: strict format, analyzer, entire Flutter test suite, debug APK and required local Gitleaks scan. Supabase/RLS/migration task descriptions require `MIZZY_RUN_SUPABASE_TESTS=1` with a ready local Supabase CLI and Docker/test stack; this runs local database tests and never deploys to hosted Supabase.
