# Mizzy project instructions for Claude Code

Follow `AGENT.md` as the canonical policy and `docs/agent-orchestration.md` for task routing and peer review.

## Required behavior
- Stay in the current Mizzy repository and feature branch; never edit `main` directly.
- Use one write-capable agent at a time. Parallel peers may inspect or review but must not modify the same checkout.
- Establish acceptance criteria, make a minimal patch, add/update tests, run real verification commands, inspect the diff, and disclose unverified items.
- For auth, RLS, tenant/branch scope, payment/refund, inventory ledger, offline sync and migrations, do a read-only security review and negative tests.
- End with `VERDICT: PASS`, `VERDICT: CHANGES_REQUIRED`, or `VERDICT: BLOCKED` on the first line of the final response.
- Do not commit/push/merge, deploy, publish, provision paid infrastructure, alter production data, or change repository visibility without explicit authorization.
- Never expose secrets. Do not put Supabase service-role keys into the Android client.
- If GitHub Actions jobs fail with runner ID zero and no steps/logs, classify as an infrastructure blocker, not a source regression.
