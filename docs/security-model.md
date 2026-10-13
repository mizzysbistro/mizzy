# Security model baseline

**Status:** design baseline; SQL migration is a draft until applied to an isolated Supabase test project and negative tests pass.

## Identity and tenant scope

Supabase Auth identifies the caller. Organization membership establishes tenant membership. Branch membership grants a branch-scoped role (manager, counter, or kitchen). The owner role is organization-scoped. Never trust organization, branch, or user IDs supplied by the app without checking that the authenticated user has the corresponding membership.

## Enforcement

- Enable RLS on every exposed tenant-owned table.
- Default deny: no write grant or policy until the exact operation is designed.
- Use only authenticated for application data; unauthenticated reads/writes must be denied.
- Helpers that read membership tables use SECURITY DEFINER only with SET search_path = '', schema-qualified references, narrowly granted EXECUTE rights, and predicates tied to auth.uid().
- Membership changes and audit event creation are not directly writable by clients in the initial migration. A future trusted workflow must validate invitations/roles and write audit history.
- Never let managers, Counter, or Kitchen assign themselves or another user the Owner role.
- All policies need positive member cases plus negative unauthenticated, wrong-organization, wrong-branch and wrong-role cases.
- Use least-privilege database grants in addition to RLS. RLS policies alone do not remove table grants.
- Secrets belong in environment/CI secret stores. An Android client may contain a Supabase publishable/anon key; it must never contain the service-role key.

## Initial role scope

| Operation | Owner | Manager (assigned branch) | Counter (assigned branch) | Kitchen (assigned branch) |
|---|---|---|---|---|
| Read organization/branch basics | Yes | Membership scope | Membership scope | Membership scope |
| Create organization / branch | Yes | No in initial baseline | No | No |
| Edit branch settings | Yes | Limited branch policy | No | No |
| POS and table operations | Yes | Yes | Yes | Read assigned kitchen context only |
| Kitchen status transitions | Yes | Yes | View status | Yes, assigned tickets only |
| Manage membership/roles | Owner-only trusted workflow | No | No | No |
| Organization-wide reports/settings | Yes | No | No | No |

These are initial least-privilege rules, not a claim that all listed app workflows are implemented.

## Required verification before production

Run migrations against a disposable Supabase local/test stack. Test organization creation, duplicate names/branches, membership scoping, all role combinations, cross-tenant access, cross-branch access, unauthenticated calls, direct table writes, and audit immutability. Review function grants and generated API exposure. Do not deploy the draft migration to a production database without explicit approval.
