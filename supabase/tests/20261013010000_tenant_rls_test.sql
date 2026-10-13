begin;

create extension if not exists pgtap with schema extensions;

select plan(19);

-- Seed isolated test identities and tenant records as the database test owner.
insert into auth.users (
  id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('10000000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'owner-a@example.invalid', '', now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now()),
  ('10000000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'counter-a@example.invalid', '', now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now()),
  ('10000000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'manager-a@example.invalid', '', now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now()),
  ('10000000-0000-4000-8000-000000000004', 'authenticated', 'authenticated', 'kitchen-a@example.invalid', '', now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now()),
  ('20000000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'owner-b@example.invalid', '', now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now()),
  ('20000000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'counter-b@example.invalid', '', now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now());

insert into public.organizations (id, name, created_by) values
  ('aaaaaaaa-0000-4000-8000-000000000001', 'RLS Test Org A', '10000000-0000-4000-8000-000000000001'),
  ('bbbbbbbb-0000-4000-8000-000000000001', 'RLS Test Org B', '20000000-0000-4000-8000-000000000001');

insert into public.branches (id, organization_id, name) values
  ('aaaaaaaa-0000-4000-8000-000000000011', 'aaaaaaaa-0000-4000-8000-000000000001', 'A Main'),
  ('aaaaaaaa-0000-4000-8000-000000000012', 'aaaaaaaa-0000-4000-8000-000000000001', 'A Second'),
  ('bbbbbbbb-0000-4000-8000-000000000011', 'bbbbbbbb-0000-4000-8000-000000000001', 'B Main');

insert into public.organization_memberships (organization_id, user_id, role) values
  ('aaaaaaaa-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001', 'owner'),
  ('aaaaaaaa-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000002', 'member'),
  ('aaaaaaaa-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000003', 'member'),
  ('aaaaaaaa-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000004', 'member'),
  ('bbbbbbbb-0000-4000-8000-000000000001', '20000000-0000-4000-8000-000000000001', 'owner'),
  ('bbbbbbbb-0000-4000-8000-000000000001', '20000000-0000-4000-8000-000000000002', 'member');

insert into public.branch_memberships (organization_id, branch_id, user_id, role) values
  ('aaaaaaaa-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-000000000011', '10000000-0000-4000-8000-000000000002', 'counter'),
  ('aaaaaaaa-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-000000000011', '10000000-0000-4000-8000-000000000003', 'manager'),
  ('aaaaaaaa-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-000000000011', '10000000-0000-4000-8000-000000000004', 'kitchen'),
  ('bbbbbbbb-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-000000000011', '20000000-0000-4000-8000-000000000002', 'counter');

insert into public.audit_events (organization_id, branch_id, actor_id, action, entity_type, entity_id)
values
  ('aaaaaaaa-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-000000000011', '10000000-0000-4000-8000-000000000003', 'test', 'branch', 'a-event'),
  ('bbbbbbbb-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-000000000011', '20000000-0000-4000-8000-000000000001', 'test', 'branch', 'b-event');

set local role authenticated;
set local request.jwt.claim.sub = '10000000-0000-4000-8000-000000000001';
select is((select count(*)::integer from public.organizations), 1, 'owner reads only their own organization');
select is((select count(*)::integer from public.branches), 2, 'owner reads all branches in their organization');
select is((select count(*)::integer from public.organization_memberships), 4, 'owner can view membership directory');
select is((select count(*)::integer from public.branch_memberships), 3, 'owner can view branch assignments');

set local request.jwt.claim.sub = '10000000-0000-4000-8000-000000000002';
select is((select count(*)::integer from public.organizations), 1, 'counter reads their own organization');
select is((select count(*)::integer from public.organizations where id = 'bbbbbbbb-0000-4000-8000-000000000001'), 0, 'counter cannot read another organization');
select is((select count(*)::integer from public.branches), 1, 'counter reads only assigned branch');
with changed as (
  update public.branches set name = 'Unauthorized rename'
  where id = 'bbbbbbbb-0000-4000-8000-000000000011'
  returning id
)
select is((select count(*)::integer from changed), 0, 'counter cannot modify another tenant branch');
select is((select count(*)::integer from public.audit_events), 0, 'counter cannot read manager/owner audit events');
select is((select count(*)::integer from public.organization_memberships), 0, 'counter cannot list organization memberships');
select is((select count(*)::integer from public.branch_memberships), 0, 'counter cannot list staff branch assignments');

set local request.jwt.claim.sub = '10000000-0000-4000-8000-000000000003';
select is((select count(*)::integer from public.branches), 1, 'manager reads only their assigned branch');
select is((select count(*)::integer from public.audit_events), 1, 'manager can read audit events for their branch');
select is((select count(*)::integer from public.audit_events where organization_id = 'bbbbbbbb-0000-4000-8000-000000000001'), 0, 'manager cannot read another organization audit events');
select is((select count(*)::integer from public.branch_memberships), 3, 'manager can view assignments for their branch');

set local request.jwt.claim.sub = '10000000-0000-4000-8000-000000000004';
select is((select count(*)::integer from public.branches), 1, 'kitchen reads only assigned branch');
select is((select count(*)::integer from public.audit_events), 0, 'kitchen cannot read audit events');

set local request.jwt.claim.sub = '20000000-0000-4000-8000-000000000002';
select is((select count(*)::integer from public.organizations), 1, 'second tenant counter reads only their organization');

reset role;
set local role anon;
set local request.jwt.claim.sub = '';
select ok(not has_table_privilege('anon', 'public.organizations', 'SELECT'), 'anonymous caller has no organization table privilege');
select ok(not has_table_privilege('anon', 'public.branches', 'SELECT'), 'anonymous caller has no branch table privilege');

select * from finish();
rollback;
