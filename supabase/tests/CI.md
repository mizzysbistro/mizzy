# Local database CI

The `.github/workflows/supabase-tests.yml` workflow starts a throwaway Supabase stack on the runner, applies all migrations to a fresh local database, runs pgTAP schema/grant and RLS tests, then stops the stack. It has no production URL or privileged cloud secret configured.

Treat CI output as the source of truth: a migration file being present in Git does not mean it has applied successfully or passed access-control tests. Correct SQL/test failures in separate safe commits and rerun the workflow. Keep any local test identities and fixtures synthetic. The validation branch temporarily asks the CLI to generate the next P1 migration filename; this step is diagnostic and must be removed before merging this pull request.
