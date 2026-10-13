# Supabase migration verification plan

These checks are a starting smoke suite, not evidence that the schema is production-safe. Run them only against a disposable Supabase local/test database after applying all migrations with the Supabase CLI. Do not connect tests to production data.

## Run

1. Install the Supabase CLI using its official installation instructions.
2. Start a local stack and apply migrations with `supabase start` and `supabase db reset`.
3. Run database tests with `supabase test db`.
4. Capture CLI version, migration output, test output, and test database reset state in the P0 issue.
5. Add real authenticated/unauthenticated positive and negative RLS tests before declaring P0-06 verified.

## Required authorization test matrix

- An unauthenticated caller cannot read/write organizations, branches, memberships, or audit events.
- An active organization member can read only their organization's rows.
- A member from a different organization cannot read or mutate the first organization's rows.
- A branch manager can only act within branch membership; manager access in branch A does not grant branch B access.
- Counter and Kitchen cannot insert/update/delete branch membership, grant roles, or write audit events directly.
- Counter can never elevate self or another account to Owner.
- Only an authenticated caller can bootstrap an organization through the RPC; the RPC creates the owner membership and initial branch atomically.
- Direct writes to organizations, memberships and audit events remain denied to ordinary clients.
- Branch name/status updates are the only columns granted for general branch updates; organization_id and id are not mutable by an authenticated client.
- Duplicate organization/branch membership constraints and malformed names fail safely.
- SECURITY DEFINER functions pin search_path to empty, qualify object names, and have narrowly scoped EXECUTE grants.
- Transaction rollback leaves no partial organization if branch creation fails.

Implemented SQL tests now include a catalog/grant smoke suite and a separate 21-assertion role/RLS suite using isolated test identities. These tests have not been executed yet. The bootstrap-RPC rollback and unauthorized role-change cases are still additional coverage required before RLS is marked verified.
