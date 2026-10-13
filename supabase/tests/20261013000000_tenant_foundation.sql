begin;

create extension if not exists pgtap with schema extensions;

select plan(18);

select ok(
  exists (select 1 from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relname = 'organizations' and c.relkind = 'r'),
  'organizations table exists'
);
select ok(
  exists (select 1 from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relname = 'branches' and c.relkind = 'r'),
  'branches table exists'
);
select ok(
  exists (select 1 from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relname = 'organization_memberships' and c.relkind = 'r'),
  'organization_memberships table exists'
);
select ok(
  exists (select 1 from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relname = 'branch_memberships' and c.relkind = 'r'),
  'branch_memberships table exists'
);
select ok(
  exists (select 1 from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relname = 'audit_events' and c.relkind = 'r'),
  'audit_events table exists'
);

select ok(
  (select c.relrowsecurity from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relname = 'organizations'),
  'RLS enabled on organizations'
);
select ok(
  (select c.relrowsecurity from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relname = 'branches'),
  'RLS enabled on branches'
);
select ok(
  (select c.relrowsecurity from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relname = 'organization_memberships'),
  'RLS enabled on organization_memberships'
);
select ok(
  (select c.relrowsecurity from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relname = 'branch_memberships'),
  'RLS enabled on branch_memberships'
);
select ok(
  (select c.relrowsecurity from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relname = 'audit_events'),
  'RLS enabled on audit_events'
);

select ok(
  not has_table_privilege('anon', 'public.organizations', 'SELECT'),
  'anon cannot directly select organizations'
);
select ok(
  not has_table_privilege('anon', 'public.branches', 'INSERT'),
  'anon cannot directly insert branches'
);
select ok(
  not has_table_privilege('authenticated', 'public.organization_memberships', 'INSERT'),
  'authenticated clients cannot directly add organization memberships'
);
select ok(
  not has_table_privilege('authenticated', 'public.audit_events', 'INSERT'),
  'authenticated clients cannot directly forge audit events'
);
select ok(
  has_function_privilege('authenticated', 'public.create_organization(text,text)', 'EXECUTE'),
  'authenticated users can call the organization bootstrap RPC'
);
select ok(
  not has_function_privilege('anon', 'public.create_organization(text,text)', 'EXECUTE'),
  'anonymous users cannot call the organization bootstrap RPC'
);
select ok(
  not has_column_privilege('authenticated', 'public.branches', 'organization_id', 'UPDATE'),
  'authenticated clients cannot change a branch tenant identifier'
);
select ok(
  has_column_privilege('authenticated', 'public.branches', 'name', 'UPDATE'),
  'authenticated clients have column-level permission to update branch name subject to RLS'
);

select * from finish();
rollback;
