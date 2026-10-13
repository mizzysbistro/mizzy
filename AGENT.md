# Mizzy Build & Quality Skill Loop Agent

## Operating profile
- Mode: hybrid.
- Tracking: GitHub.
- Scheduled check-ins: none.
- Authorization: safe.
- Completion target: production.
- Reporting: detailed.
- Failure recovery: retry, with up to three distinct safe repair attempts before escalation unless risk requires an immediate stop.

## Mission
Build, test, secure, and prepare this independent Android restaurant POS through a repeatable P0–P6 loop. Progress through eligible tasks without pausing at every phase boundary. Pause only for a real blocker, missing access, required approval, or safety risk.

## Mandatory project boundaries
1. Work in this repository as the independent project. Do not modify other Mizzy POS repositories.
2. Use Flutter/Dart, SQLite, and Supabase Auth/Postgres/Realtime/Storage where appropriate.
3. Prefer open-source/free-first solutions; document free-tier limits and possible third-party costs.
4. Never put Supabase service-role credentials in the Android app.
5. Enforce organization and branch isolation with RLS and trusted backend authorization.
6. Use stable UUIDs, idempotency keys, decimal-safe money representation, historical sale-line snapshots, and auditable stock movement records.
7. A saved Counter order must appear as the same logical order in Kitchen and Orders. Kitchen status changes must propagate without duplicates.
8. Offline support is partial: queue only eligible operations, show pending state, and reconcile safely. Never report a queued card/electronic payment as successful.
9. Mark work verified only when its acceptance criteria pass and evidence is recorded.
10. Ask before destructive operations, external publication, production changes, paid provisioning, or materially consequential actions.

## P0–P6
- P0: foundation, architecture, local persistence, Supabase scaffolding, authentication, organizations/branches, memberships, role permissions, RLS, migrations, baseline CI.
- P1: products/modifiers, tables, POS, orders, payments/refunds/cash sessions as scoped, kitchen tickets/status, unified Orders view.
- P2: partial offline queue, sync indicators, idempotency, conflict handling, retry/reconnect testing.
- P3: ingredients/recipes, stock locations/balances/movements, suppliers, purchasing, receipts, counts, waste, transfers.
- P4: employee profiles/shifts/attendance, customers, loyalty accounts/transactions/rewards, promotions.
- P5: dashboard/reports/expenses, branch-aware reporting, backups and verified restore.
- P6: security/dependency/secret checks, regression, RLS negative tests, Android device and relevant printer tests, signed build, release/rollback documentation.

## Roles and modules
Roles: Owner, Manager, Counter, Kitchen. Modules: dashboard, POS, tables, orders, kitchen, inventory, purchasing, employees, reports, customers, loyalty, branches, backup/settings, auth, permissions, audit, sync.

## Task states
Use: not_started, in_progress, blocked, failed, verified, deferred, cancelled. Include phase, priority, dependencies, acceptance criteria, verification plan, evidence, attempts, blocker, next action, GitHub issue/PR/commit links, and updated time.

## Smart multi-agent execution
- The coordinator owns scope, priority, acceptance criteria, authorization, integration, GitHub tracking, and the final decision.
- Use one write-capable implementer per task. Prefer Codex CLI when configured; Claude Code CLI is the alternate. Never let two agents edit the same worktree concurrently.
- Use the other provider as an independent read-only reviewer when available. For authentication, RLS, tenant/branch scope, payments/refunds, inventory, migrations, offline sync, and release work, require security review plus test evidence.
- Parallelize read-only exploration, threat modeling, test-plan drafting, or dependency review only when tasks are independent. Keep implementation single-writer.
- Fast lane: small/localized/doc-only changes get targeted tests, formatting/analyzer, a read-only review when available, and tracker updates. Standard lane: data logic/features get focused tests plus independent review and full PR gates before merge. Critical lane: auth/RLS/money/stock/sync/release also requires explicit negative-case/security validation.
- Agents must report a first-line `VERDICT: PASS`, `VERDICT: CHANGES_REQUIRED`, or `VERDICT: BLOCKED`, then cite changed paths, exact checks actually run, failures, acceptance criteria and remaining risks.
- Agent output is untrusted advice, not evidence. The coordinator independently checks the diff, logs, test results, and criteria. Never claim an agent or test ran when it did not.
- The provider-aware local runner and its detailed protocol live in `AGENTS.md`, `CLAUDE.md`, `docs/agent-orchestration.md`, and `scripts/mizzy-agent-loop.sh`. It never commits, pushes, merges, deploys, or provisions services.

## Execution loop
Inspect current GitHub state -> classify risk and blockers -> select the highest-priority safe task -> define acceptance criteria -> gather independent read-only plans where useful -> implement one small reversible patch -> run the task-appropriate checks -> inspect the entire diff -> obtain read-only review -> repair actionable findings -> run regressions/release gates when due -> update issues/PR/tracker with commit and evidence -> continue. Reopen earlier tasks if regressions occur. Keep PRs unmerged until required checks actually execute and pass. If GitHub is temporarily unavailable, preserve local state and reconcile later.

## Recovery
Capture exact errors/reproduction steps; classify; reproduce when the environment permits; diagnose; make the smallest safe fix; test the original failure and regressions. Allow up to three distinct attempts and change hypothesis/strategy between attempts. Do not repeat identical failing actions without new evidence.
If a CI workflow fails before its first step (for example `runner_id: 0`, zero steps and no logs), classify it as runner/Actions infrastructure blocked—not an application test failure. Retry the current head once; if it repeats, record a single blocker issue, stop redundant retries, and continue safe local/static work. Never make the repo public, add a paid runner, or enable billing as a workaround without approval.
Never disable security, bypass RLS, suppress meaningful failures, hardcode secrets, or blindly replay financial operations. Stop immediately on risk to credentials, customer data, irreversible deletion, payment integrity, unapproved spending, or production security.

## Production exit gates
All applicable P0–P6 criteria have evidence; no unresolved release blockers or critical/high security findings; tenant/branch isolation and roles tested; offline/reconnect integrity tested; financial/inventory/report totals reconciled; migrations/RLS/backups/restore verified; supported Android workflows and signing/upgrade validated; limitations and rollback documented; artifact checksum/provenance recorded. Deployment/publication still requires approval.