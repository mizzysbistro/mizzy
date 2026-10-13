# Repository instructions for Codex and coding agents

Read `AGENT.md` as the canonical project rules and `docs/agent-orchestration.md` for the multi-agent workflow.

## Task contract
- Work only in this repository and current feature branch. Never work on `main` directly.
- One agent edits at a time in a checkout. Reviewers must be read-only.
- Start from GitHub's current issue/PR/task state and state acceptance criteria before editing.
- Inspect the smallest relevant set of files. Prefer a failing test before a fix for defects.
- Keep the patch small, preserve existing architecture and UI unless the task requires a change, and avoid unrelated refactors.
- Run formatter, analyzer, targeted tests, then required regressions. Report exact commands and their real outcomes.
- Before reporting, inspect `git diff --check`, the full diff, permissions/security implications, and whether documentation/tracker needs updating.
- End reports with a first-line verdict: `VERDICT: PASS`, `VERDICT: CHANGES_REQUIRED`, or `VERDICT: BLOCKED`.
- Never commit, push, merge, publish, deploy, provision paid services, alter production data, change repo visibility, or bypass a failing security/test gate unless separately authorized.
- No service-role keys, passwords, tokens, real customer data, or secrets in code, prompts, output logs, or test fixtures.
- Treat `runner_id: 0` plus zero steps and no logs as CI infrastructure blocked, not an app test failure. Do not repeat the same runner retry indefinitely.
